// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { HookMiner } from "v4-periphery/test/shared/HookMiner.sol";

import { Hooks } from "v4-core/libraries/Hooks.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { SwapParams } from "v4-core/types/PoolOperation.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

import { GlideSwapVMRouter } from "../../src/routers/GlideSwapVMRouter.sol";
import { GlideLens } from "../../src/periphery/GlideLens.sol";
import { GlideHook } from "../../src/hooks/GlideHook.sol";
import { WeightedMath } from "../../src/libs/WeightedMath.sol";

/// @notice End-to-end on a Unichain mainnet fork: real Aqua, real PoolManager, real WETH and USDC.
/// @dev Run with: forge test --match-path test/fork/UnichainFork.t.sol -vv   (needs network access)
contract UnichainForkTest is Test {
    address constant AQUA = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;
    address constant POOL_MANAGER = 0x1F98400000000000000000000000000000000004;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x078D782b760474a361dDA0AF3839290b0EF57AD6;
    uint256 constant FORK_BLOCK = 58230608;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    // demo assumptions: 1 ETH = 3000 USDC reference price
    uint256 constant PRICE_USDC_PER_ETH = 3000;
    uint256 constant MAKER_USDC = 3_000e6;
    uint256 constant MAKER_WETH = 5e18;

    GlideSwapVMRouter router;
    GlideLens lens;
    GlideHook hook;
    PoolSwapTest swapRouter;
    PoolKey key;

    address maker = makeAddr("maker");
    address taker = makeAddr("taker");
    GlideLens.GlideParams params;
    ISwapVM.Order order;
    bytes32 orderHash;

    PoolSwapTest.TestSettings settings = PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false });

    function setUp() public {
        string memory url = vm.envOr("UNICHAIN_RPC_URL", string("https://mainnet.unichain.org"));
        vm.createSelectFork(url, FORK_BLOCK);

        router = new GlideSwapVMRouter(AQUA, WETH, address(this));
        lens = new GlideLens(ISwapVM(address(router)), IAqua(AQUA));
        swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));

        uint160 flags = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
        (, bytes32 salt) = HookMiner.find(
            address(this), flags, type(GlideHook).creationCode, abi.encode(IPoolManager(POOL_MANAGER), ISwapVM(address(router)))
        );
        hook = new GlideHook{ salt: salt }(IPoolManager(POOL_MANAGER), ISwapVM(address(router)));

        // USDC < WETH, so tokenA = USDC
        key = PoolKey({ currency0: Currency.wrap(USDC), currency1: Currency.wrap(WETH), fee: 0, tickSpacing: 60, hooks: IHooks(address(hook)) });
        IPoolManager(POOL_MANAGER).initialize(key, SQRT_PRICE_1_1);

        deal(USDC, maker, MAKER_USDC);
        deal(WETH, maker, MAKER_WETH);

        // start weight from current value split: 3000 USDC vs 5 ETH * 3000 = 15000 -> USDC weight 1/6; glide to 70% USDC over a day
        uint64 wA0 = lens.deriveStartWeight(MAKER_USDC * 1e12, MAKER_WETH * PRICE_USDC_PER_ETH);
        params = GlideLens.GlideParams({
            tokenA: USDC,
            tokenB: WETH,
            feeBps: 0.003e7,
            start: uint40(block.timestamp),
            duration: 1 days,
            wA0: wA0,
            wA1: 0.7e18,
            salt: 42
        });
        order = lens.buildOrder(maker, params);
        orderHash = lens.orderHash(maker, params);

        address[] memory tokens = new address[](2);
        tokens[0] = USDC;
        tokens[1] = WETH;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = MAKER_USDC;
        amounts[1] = MAKER_WETH;

        vm.startPrank(maker);
        IERC20(USDC).approve(AQUA, type(uint256).max);
        IERC20(WETH).approve(AQUA, type(uint256).max);
        bytes32 shipped = IAqua(AQUA).ship(address(router), lens.encodeShipStrategy(maker, params), tokens, amounts);
        hook.registerRoute(key, order);
        vm.stopPrank();
        assertEq(shipped, orderHash);

        deal(USDC, taker, 10_000e6);
        deal(WETH, taker, 10e18);
    }

    function test_SpotPriceMatchesReferenceAtStart() public view {
        GlideLens.State memory s = lens.state(maker, params);
        assertTrue(s.active);
        // spot is WETH-wei per USDC-unit; 1 USDC (1e6) buys 1/3000 ETH = 3.33e14 wei -> 3.33e14 * 1e18 / 1e6
        uint256 expected = 1e18 * 1e18 / (PRICE_USDC_PER_ETH * 1e6);
        assertApproxEqRel(s.spotBPerA, expected, 0.001e18);
    }

    function test_DirectSwap_UsdcForEth() public {
        uint256 amountIn = 300e6;
        (, uint256 expectedOut) = lens.quote(order, true, true, amountIn);
        // 300 USDC is 10% of the USDC reserve, so the curve charges real slippage on top of the 0.3% fee
        uint256 curveOut = WeightedMath.calcOutGivenIn(MAKER_USDC, params.wA0, MAKER_WETH, 1e18 - params.wA0, amountIn * 997 / 1000);
        assertApproxEqRel(expectedOut, curveOut, 0.0001e18, "matches the weighted curve");
        assertLt(expectedOut, 0.1e18);
        assertGt(expectedOut, 0.09e18);

        uint256 makerUsdc = IERC20(USDC).balanceOf(maker);
        uint256 makerWeth = IERC20(WETH).balanceOf(maker);

        vm.startPrank(taker);
        IERC20(USDC).approve(address(router), amountIn);
        (uint256 amountInActual, uint256 amountOut,) = router.swap(order, amountIn, lens.takerData(true, true, expectedOut, address(0), 0));
        vm.stopPrank();

        assertEq(amountInActual, amountIn);
        assertEq(amountOut, expectedOut);
        assertEq(IERC20(USDC).balanceOf(maker), makerUsdc + amountIn, "maker wallet +USDC");
        assertEq(IERC20(WETH).balanceOf(maker), makerWeth - amountOut, "maker wallet -WETH");
        assertEq(IERC20(WETH).balanceOf(taker), 10e18 + amountOut);
    }

    function test_SwapViaUniswap_UsdcForEth() public {
        uint256 amountIn = 300e6;
        (, uint256 expectedOut) = lens.quote(order, true, true, amountIn);

        uint256 makerUsdc = IERC20(USDC).balanceOf(maker);
        uint256 makerWeth = IERC20(WETH).balanceOf(maker);

        vm.startPrank(taker);
        IERC20(USDC).approve(address(swapRouter), amountIn);
        swapRouter.swap(
            key,
            SwapParams({ zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 }),
            settings,
            abi.encode(expectedOut)
        );
        vm.stopPrank();

        assertEq(IERC20(USDC).balanceOf(maker), makerUsdc + amountIn, "maker wallet +USDC via Uniswap");
        assertEq(IERC20(WETH).balanceOf(maker), makerWeth - expectedOut, "maker wallet -WETH via Uniswap");
        assertEq(IERC20(WETH).balanceOf(taker), 10e18 + expectedOut);
        assertEq(IERC20(USDC).balanceOf(address(hook)), 0);
        assertEq(IERC20(WETH).balanceOf(address(hook)), 0);
    }

    function test_SwapViaUniswap_EthForUsdc() public {
        uint256 amountIn = 0.5e18;
        (, uint256 expectedOut) = lens.quote(order, true, false, amountIn);
        // 0.5 ETH is 10% of the ETH reserve; with ETH weight 5/6 the exponent is 5, so slippage is steep
        uint256 curveOut = WeightedMath.calcOutGivenIn(MAKER_WETH, 1e18 - params.wA0, MAKER_USDC, params.wA0, amountIn * 997 / 1000);
        assertApproxEqRel(expectedOut, curveOut, 0.0001e18, "matches the weighted curve");
        assertLt(expectedOut, 1_500e6);
        assertGt(expectedOut, 1_100e6);

        vm.startPrank(taker);
        IERC20(WETH).approve(address(swapRouter), amountIn);
        swapRouter.swap(
            key,
            SwapParams({ zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1 }),
            settings,
            ""
        );
        vm.stopPrank();
        assertEq(IERC20(USDC).balanceOf(taker), 10_000e6 + expectedOut);
    }

    function test_QuoteMovesWithTime() public {
        (, uint256 outNow) = lens.quote(order, true, true, 300e6);
        vm.warp(block.timestamp + 12 hours);
        (, uint256 outLater) = lens.quote(order, true, true, 300e6);
        // the USDC weight rises over the window: the maker wants more USDC, so it bids more ETH per USDC later
        assertGt(outLater, outNow);
        GlideLens.State memory s = lens.state(maker, params);
        assertApproxEqAbs(s.wA, (uint256(params.wA0) + 0.7e18) / 2, 1e12);
    }

    function test_Dock() public {
        address[] memory tokens = new address[](2);
        tokens[0] = USDC;
        tokens[1] = WETH;
        vm.prank(maker);
        IAqua(AQUA).dock(address(router), orderHash, tokens);
        GlideLens.State memory s = lens.state(maker, params);
        assertFalse(s.active);
        bytes memory data = lens.takerData(true, true, 0, address(0), 0);
        vm.startPrank(taker);
        IERC20(USDC).approve(address(router), 1e6);
        vm.expectRevert();
        router.swap(order, 1e6, data);
        vm.stopPrank();
    }
}
