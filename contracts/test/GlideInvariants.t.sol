// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { AquaSwapVMTest } from "@1inch/swap-vm/test/base/AquaSwapVMTest.sol";
import { CoreInvariants } from "@1inch/swap-vm/test/invariants/CoreInvariants.t.sol";
import { SwapVM } from "@1inch/swap-vm/src/SwapVM.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { FeeFlatIn } from "@1inch/swap-vm/src/instructions/FeeFlat.sol";
import { Salt } from "@1inch/swap-vm/src/instructions/Controls.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { GlideSwapVMRouter } from "../src/routers/GlideSwapVMRouter.sol";
import { GlideSwap } from "../src/instructions/GlideSwap.sol";

/// @notice Runs 1inch's CoreInvariants suite against Glide programs in Aqua mode.
/// @dev Tolerances, and why they are not the strict defaults:
///   - symmetry / additivity: the curve uses a fixed-point power bumped up by 1e-14 in the maker's favour on every
///     evaluation. A round trip pays that twice, so amounts of up to 100e18 drift by up to ~1e-12 relative plus the
///     value of one wei of output at the spot price. 1e9 wei on 1e18-scale amounts is 1e-9 tokens, far above the
///     observed drift and far below anything economically meaningful. Direction is always against the taker.
///   - everything else is at the suite defaults.
contract GlideInvariantsTest is AquaSwapVMTest, CoreInvariants {
    uint40 constant T0 = 1_800_000_000;
    uint32 constant DURATION = 1 days;

    uint256 constant SYMMETRY_TOLERANCE = 1e9;
    uint256 constant ADDITIVITY_TOLERANCE = 1e9;

    function setUp() public override {
        vm.warp(T0);
        super.setUp();
    }

    function _deployRouter() internal override returns (SwapVM) {
        return new GlideSwapVMRouter(address(aqua), address(0), address(this));
    }

    // ---- CoreInvariants glue ----

    function _executeSwap(
        SwapVM _swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address,
        uint256 amount,
        bytes memory data
    ) internal override returns (uint256 amountIn, uint256 amountOut) {
        (uint256 quotedIn,,) = _swapVM.asView().quote(order, amount, data);
        TokenMock(tokenIn).mint(address(taker), quotedIn);
        (amountIn, amountOut) = taker.swap(order, amount, data);
    }

    // ---- fixtures ----

    function _ship(uint24 feeBps, uint64 wA0, uint64 wA1, uint256 balA, uint256 balB) internal returns (ISwapVM.Order memory order) {
        bytes memory program = bytes.concat(
            feeBps > 0 ? FeeFlatIn.build(feeBps) : bytes(""),
            GlideSwap.build(T0 + 1 hours, DURATION, wA0, wA1),
            Salt.build(abi.encodePacked(vm.randomUint()))
        );
        order = createStrategy(program);
        tokenA.mint(maker, balA);
        tokenB.mint(maker, balB);
        shipStrategy(order, tokenA, tokenB, balA, balB);
    }

    /// @dev amounts scale with `maxAmount`; additivity swaps amount, 2*amount and 3*amount, so 3*maxAmount must
    ///      stay under the 30% caps on both the input and the output side for the fixture's balances and price
    function _amounts(uint256 maxAmount) internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](4);
        amounts[0] = maxAmount / 100;
        amounts[1] = maxAmount / 10;
        amounts[2] = maxAmount / 2;
        amounts[3] = maxAmount;
    }

    function _config(bool aToB, uint256 maxIn, uint256 maxOut) internal view returns (InvariantConfig memory config) {
        config = createInvariantConfig(_amounts(maxIn), SYMMETRY_TOLERANCE);
        config.testAmountsExactOut = _amounts(maxOut);
        config.additivityTolerance = ADDITIVITY_TOLERANCE;
        config.exactInTakerData = abi.encodePacked(takerData(address(taker), true, aToB));
        config.exactOutTakerData = abi.encodePacked(takerData(address(taker), false, aToB));
    }

    /// @param aIn max exact-in amount of A for A->B, `aOut` max exact-out amount of B for A->B, and the mirror for B->A
    function _runAll(ISwapVM.Order memory order, uint256 aIn, uint256 aOut, uint256 bIn, uint256 bOut) internal {
        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), _config(true, aIn, aOut));
        assertAllInvariantsWithConfig(swapVM, order, address(tokenB), address(tokenA), _config(false, bIn, bOut));
    }

    // ---- fixed weights, balances proportional to weights so spot is 1:1 ----

    function test_Invariants_FiftyFifty() public {
        _runAll(_ship(0, 0.5e18, 0.5e18, 1_000e18, 1_000e18), 100e18, 100e18, 100e18, 100e18);
    }

    function test_Invariants_FiftyFifty_WithFee() public {
        _runAll(_ship(0.003e7, 0.5e18, 0.5e18, 1_000e18, 1_000e18), 100e18, 100e18, 100e18, 100e18);
    }

    function test_Invariants_EightyTwenty() public {
        _runAll(_ship(0, 0.8e18, 0.8e18, 800e18, 200e18), 15e18, 15e18, 15e18, 15e18);
    }

    function test_Invariants_TwentyEighty_WithFee() public {
        _runAll(_ship(0.01e7, 0.2e18, 0.2e18, 200e18, 800e18), 15e18, 15e18, 15e18, 15e18);
    }

    function test_Invariants_ExtremeWeights() public {
        _runAll(_ship(0, 0.99e18, 0.99e18, 990e18, 10e18), 0.9e18, 0.9e18, 0.9e18, 0.9e18);
        _runAll(_ship(0, 0.01e18, 0.01e18, 10e18, 990e18), 0.9e18, 0.9e18, 0.9e18, 0.9e18);
    }

    // ---- fixed balances 800/200 with weights gliding 80% -> 20%, at three points in time ----

    function test_Invariants_Glide_BeforeStart() public {
        // weight 0.8, spot 1:1
        _runAll(_ship(0.003e7, 0.8e18, 0.2e18, 800e18, 200e18), 15e18, 15e18, 15e18, 15e18);
    }

    function test_Invariants_Glide_Midway() public {
        // weight 0.5, spot 0.25 B per A: A is cheap, B is dear
        ISwapVM.Order memory order = _ship(0.003e7, 0.8e18, 0.2e18, 800e18, 200e18);
        vm.warp(T0 + 1 hours + DURATION / 2);
        _runAll(order, 60e18, 15e18, 15e18, 50e18);
    }

    function test_Invariants_Glide_AfterEnd() public {
        // weight 0.2, spot 0.0625 B per A
        ISwapVM.Order memory order = _ship(0.003e7, 0.8e18, 0.2e18, 800e18, 200e18);
        vm.warp(T0 + 1 hours + DURATION + 1);
        _runAll(order, 60e18, 3e18, 5e18, 50e18);
    }

    // ---- quote never changes within a block ----

    function test_QuoteIsStableWithinBlock() public {
        ISwapVM.Order memory order = _ship(0.003e7, 0.8e18, 0.2e18, 1_000e18, 1_000e18);
        vm.warp(T0 + 1 hours + 12345);
        bytes memory data = abi.encodePacked(takerData(address(taker), true, true));
        (, uint256 out1,) = swapVM.asView().quote(order, 10e18, data);
        (, uint256 out2,) = swapVM.asView().quote(order, 10e18, data);
        assertEq(out1, out2);
    }
}
