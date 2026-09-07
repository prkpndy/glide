// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";
import { HookMiner } from "v4-periphery/test/shared/HookMiner.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";

import { Hooks } from "v4-core/libraries/Hooks.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { ModifyLiquidityParams, SwapParams } from "v4-core/types/PoolOperation.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";

import { V4Artifacts } from "./utils/V4Artifacts.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

import { GlideSwapVMRouter } from "../src/routers/GlideSwapVMRouter.sol";
import { GlideLens } from "../src/periphery/GlideLens.sol";
import { GlideHook } from "../src/hooks/GlideHook.sol";

contract GlideHookTest is Test {
    uint40 constant T0 = 1_800_000_000;
    uint256 constant BAL = 1_000e18;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    IPoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest modifyLiquidityRouter;
    Currency currency0;
    Currency currency1;
    PoolKey key;

    Aqua aqua;
    GlideSwapVMRouter router;
    GlideLens lens;
    GlideHook hook;

    MockERC20 tokenA;
    MockERC20 tokenB;

    address maker = makeAddr("maker");
    GlideLens.GlideParams params;
    ISwapVM.Order order;
    bytes32 orderHash;

    PoolSwapTest.TestSettings settings = PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false });

    function setUp() public {
        vm.warp(T0);

        manager = IPoolManager(V4Artifacts.deployPoolManager(address(this)));
        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        tokenA = new MockERC20("Token A", "A", 18);
        tokenB = new MockERC20("Token B", "B", 18);
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);
        currency0 = Currency.wrap(address(tokenA));
        currency1 = Currency.wrap(address(tokenB));
        tokenA.mint(address(this), 1e30);
        tokenB.mint(address(this), 1e30);
        // Flash accounting: the hook takes the swapper's input from the PoolManager's aggregate float during
        // beforeSwap, before the swapper settles. A live PoolManager always holds other pools' reserves; a fresh
        // one holds nothing, so simulate other pools' liquidity here.
        tokenA.mint(address(manager), 1e24);
        tokenB.mint(address(manager), 1e24);
        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);
        tokenA.approve(address(modifyLiquidityRouter), type(uint256).max);
        tokenB.approve(address(modifyLiquidityRouter), type(uint256).max);

        aqua = new Aqua();
        router = new GlideSwapVMRouter(address(aqua), address(0), address(this));
        lens = new GlideLens(ISwapVM(address(router)), aqua);

        uint160 flags = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
        (address expected, bytes32 salt) = HookMiner.find(
            address(this), flags, type(GlideHook).creationCode, abi.encode(manager, ISwapVM(address(router)))
        );
        hook = new GlideHook{ salt: salt }(manager, ISwapVM(address(router)));
        assertEq(address(hook), expected, "hook address flags");

        key = _initPool(60);

        // maker: 50/50 position, 0.3% fee
        tokenA.mint(maker, BAL);
        tokenB.mint(maker, BAL);
        params = GlideLens.GlideParams({
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            feeBps: 0.003e7,
            start: T0,
            duration: 1 days,
            wA0: 0.5e18,
            wA1: 0.5e18,
            salt: 1
        });
        order = lens.buildOrder(maker, params);
        orderHash = lens.orderHash(maker, params);

        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = BAL;
        amounts[1] = BAL;

        vm.startPrank(maker);
        tokenA.approve(address(aqua), type(uint256).max);
        tokenB.approve(address(aqua), type(uint256).max);
        bytes32 shipped = aqua.ship(address(router), lens.encodeShipStrategy(maker, params), tokens, amounts);
        hook.registerRoute(key, order);
        vm.stopPrank();
        assertEq(shipped, orderHash, "strategy hash == order hash");
    }

    function _initPool(int24 tickSpacing) internal returns (PoolKey memory k) {
        k = PoolKey({ currency0: currency0, currency1: currency1, fee: 0, tickSpacing: tickSpacing, hooks: IHooks(address(hook)) });
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    function _swapParams(bool zeroForOne, uint256 amountIn) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function test_SwapThroughUniswap_FillsFromMakerWallet() public {
        uint256 amountIn = 10e18;
        (, uint256 expectedOut) = lens.quote(order, true, true, amountIn);
        assertGt(expectedOut, 0);

        uint256 makerA = tokenA.balanceOf(maker);
        uint256 makerB = tokenB.balanceOf(maker);
        uint256 meA = tokenA.balanceOf(address(this));
        uint256 meB = tokenB.balanceOf(address(this));
        uint256 pmA = tokenA.balanceOf(address(manager));
        uint256 pmB = tokenB.balanceOf(address(manager));

        swapRouter.swap(key, _swapParams(true, amountIn), settings, abi.encode(expectedOut));

        assertEq(tokenA.balanceOf(maker), makerA + amountIn, "maker received A incl. fee");
        assertEq(tokenB.balanceOf(maker), makerB - expectedOut, "maker paid B");
        assertEq(tokenA.balanceOf(address(this)), meA - amountIn, "swapper paid A");
        assertEq(tokenB.balanceOf(address(this)), meB + expectedOut, "swapper got B");

        // nothing is left behind anywhere in the middle
        assertEq(tokenA.balanceOf(address(manager)), pmA, "manager float unchanged");
        assertEq(tokenB.balanceOf(address(manager)), pmB, "manager float unchanged");
        assertEq(tokenA.balanceOf(address(hook)), 0);
        assertEq(tokenB.balanceOf(address(hook)), 0);
        assertEq(tokenA.balanceOf(address(router)), 0);
        assertEq(tokenB.balanceOf(address(router)), 0);

        (uint256 aquaA, uint256 aquaB) = aqua.safeBalances(maker, address(router), orderHash, address(tokenA), address(tokenB));
        assertEq(aquaA, BAL + amountIn);
        assertEq(aquaB, BAL - expectedOut);
    }

    function test_SwapThroughUniswap_OtherDirection() public {
        uint256 amountIn = 25e18;
        (, uint256 expectedOut) = lens.quote(order, true, false, amountIn);

        uint256 makerA = tokenA.balanceOf(maker);
        uint256 makerB = tokenB.balanceOf(maker);

        swapRouter.swap(key, _swapParams(false, amountIn), settings, "");

        assertEq(tokenB.balanceOf(maker), makerB + amountIn);
        assertEq(tokenA.balanceOf(maker), makerA - expectedOut);
    }

    function test_UniswapQuoteEqualsDirectQuote() public {
        // the hook adds nothing on top: a direct router swap and a Uniswap swap of the same size pay the same
        uint256 amountIn = 10e18;
        (, uint256 direct) = lens.quote(order, true, true, amountIn);

        uint256 before = tokenB.balanceOf(address(this));
        swapRouter.swap(key, _swapParams(true, amountIn), settings, "");
        assertEq(tokenB.balanceOf(address(this)) - before, direct);
    }

    function test_MinOutEnforced() public {
        uint256 amountIn = 10e18;
        (, uint256 expectedOut) = lens.quote(order, true, true, amountIn);
        vm.expectRevert();
        swapRouter.swap(key, _swapParams(true, amountIn), settings, abi.encode(expectedOut + 1));
    }

    function test_ExactOutReverts() public {
        SwapParams memory p = SwapParams({ zeroForOne: true, amountSpecified: int256(1e18), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 });
        vm.expectRevert();
        swapRouter.swap(key, p, settings, "");
    }

    function test_AddLiquidityReverts() public {
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({ tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0 }), ""
        );
    }

    function test_NoRouteReverts() public {
        PoolKey memory other = _initPool(10);
        vm.expectRevert();
        swapRouter.swap(other, _swapParams(true, 1e18), settings, "");
    }

    function test_ClearRoute() public {
        vm.prank(maker);
        hook.clearRoute(key);
        (address m,) = hook.route(key);
        assertEq(m, address(0));
        vm.expectRevert();
        swapRouter.swap(key, _swapParams(true, 1e18), settings, "");
    }

    function test_OnlyMakerRegistersOrClears() public {
        vm.expectRevert(GlideHook.GlideHookNotMaker.selector);
        hook.registerRoute(key, order);
        vm.expectRevert(GlideHook.GlideHookNotMaker.selector);
        hook.clearRoute(key);
    }

    function test_RegisterRejectsMismatchedTokens() public {
        MockERC20 other = new MockERC20("X", "X", 18);
        GlideLens.GlideParams memory p = params;
        p.tokenA = address(other) < address(tokenB) ? address(other) : address(tokenB);
        p.tokenB = address(other) < address(tokenB) ? address(tokenB) : address(other);
        ISwapVM.Order memory o = lens.buildOrder(maker, p);
        vm.prank(maker);
        vm.expectRevert(GlideHook.GlideHookTokenMismatch.selector);
        hook.registerRoute(key, o);
    }

    function test_GlidingPositionThroughUniswap() public {
        // re-point the pool at a gliding position and check the Uniswap price follows the weight
        GlideLens.GlideParams memory p = params;
        p.wA0 = 0.8e18;
        p.wA1 = 0.2e18;
        p.salt = 2;
        ISwapVM.Order memory o = lens.buildOrder(maker, p);
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 800e18;
        amounts[1] = 200e18;
        tokenA.mint(maker, 800e18);
        tokenB.mint(maker, 200e18);
        vm.startPrank(maker);
        aqua.ship(address(router), lens.encodeShipStrategy(maker, p), tokens, amounts);
        hook.registerRoute(key, o);
        vm.stopPrank();

        uint256 probe = 1e15;
        uint256 b0 = tokenB.balanceOf(address(this));
        swapRouter.swap(key, _swapParams(true, probe), settings, "");
        uint256 outBefore = tokenB.balanceOf(address(this)) - b0;
        assertApproxEqRel(outBefore, probe * 997 / 1000, 0.002e18, "spot ~1 before glide");

        vm.warp(T0 + 12 hours);
        b0 = tokenB.balanceOf(address(this));
        swapRouter.swap(key, _swapParams(true, probe), settings, "");
        uint256 outMid = tokenB.balanceOf(address(this)) - b0;
        assertApproxEqRel(outMid, probe * 997 / 4000, 0.002e18, "spot ~0.25 midway");
    }
}
