// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { AquaSwapVMTest } from "@1inch/swap-vm/test/base/AquaSwapVMTest.sol";
import { SwapVM } from "@1inch/swap-vm/src/SwapVM.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { FeeFlatIn } from "@1inch/swap-vm/src/instructions/FeeFlat.sol";
import { Salt } from "@1inch/swap-vm/src/instructions/Controls.sol";

import { GlideSwapVMRouter } from "../src/routers/GlideSwapVMRouter.sol";
import { GlideSwap } from "../src/instructions/GlideSwap.sol";
import { WeightedMath } from "../src/libs/WeightedMath.sol";

/// @dev External wrapper so build-time reverts can be asserted
contract GlideSwapBuilder {
    function build(uint40 start, uint32 duration, uint64 wA0, uint64 wA1) external pure returns (bytes memory) {
        return GlideSwap.build(start, duration, wA0, wA1);
    }
}

contract GlideSwapTest is AquaSwapVMTest {
    uint40 constant T0 = 1_800_000_000;
    uint32 constant DURATION = 1 days;

    function setUp() public override {
        vm.warp(T0);
        super.setUp();
    }

    function _deployRouter() internal override returns (SwapVM) {
        return new GlideSwapVMRouter(address(aqua), address(0), address(this));
    }

    // ---- helpers ----

    function _program(uint24 feeBps, uint40 start, uint64 wA0, uint64 wA1) internal view returns (bytes memory) {
        return bytes.concat(
            feeBps > 0 ? FeeFlatIn.build(feeBps) : bytes(""),
            GlideSwap.build(start, DURATION, wA0, wA1),
            Salt.build(abi.encodePacked(vm.randomUint()))
        );
    }

    function _ship(bytes memory program, uint256 balA, uint256 balB) internal returns (ISwapVM.Order memory order) {
        order = createStrategy(program);
        tokenA.mint(maker, balA);
        tokenB.mint(maker, balB);
        shipStrategy(order, tokenA, tokenB, balA, balB);
    }

    function _sp(bool aToB, bool isExactIn, uint256 amount) internal view returns (SwapProgram memory) {
        return SwapProgram({ amount: amount, taker: taker, tokenA: tokenA, tokenB: tokenB, zeroForOne: aToB, isExactIn: isExactIn });
    }

    function _quote(ISwapVM.Order memory order, bool aToB, bool isExactIn, uint256 amount) internal view returns (uint256 amountIn, uint256 amountOut) {
        return quote(_sp(aToB, isExactIn, amount), order);
    }

    function _swap(ISwapVM.Order memory order, bool aToB, bool isExactIn, uint256 amount) internal returns (uint256 amountIn, uint256 amountOut) {
        SwapProgram memory sp = _sp(aToB, isExactIn, amount);
        (uint256 qIn,) = quote(sp, order);
        mintTokenInToTaker(sp, qIn);
        return swap(sp, order);
    }

    /// @dev tokenB received per tokenA for a tiny probe trade, WAD
    function _spotAToB(ISwapVM.Order memory order) internal view returns (uint256) {
        (uint256 aIn, uint256 bOut) = _quote(order, true, true, 1e12);
        return bOut * ONE / aIn;
    }

    // ---- curve anchors ----

    function test_FiftyFifty_MatchesConstantProduct() public {
        ISwapVM.Order memory order = _ship(_program(0, T0 - 1, 0.5e18, 0.5e18), 1_000e18, 1_000e18);
        (, uint256 out) = _quote(order, true, true, 10e18);
        uint256 amountIn = 10e18;
        uint256 xyc = amountIn * 1_000e18 / 1_010e18;
        assertLe(out, xyc);
        assertLe(xyc - out, 1_000e18 / 1e13 + 2);
    }

    function test_SpotPrice_FollowsWeights() public {
        // 800/200 balances with 80/20 weights: spot is 1:1
        ISwapVM.Order memory order = _ship(_program(0, T0 - 1, 0.8e18, 0.8e18), 800e18, 200e18);
        assertApproxEqRel(_spotAToB(order), 1e18, 0.001e18);

        // the other direction is also 1:1
        (uint256 bIn, uint256 aOut) = _quote(order, false, true, 1e12);
        assertApproxEqRel(aOut * ONE / bIn, 1e18, 0.001e18);
    }

    // ---- time behaviour ----

    function test_WeightAt_LinearAndClamped() public pure {
        uint40 start = T0 + 1 hours;
        assertEq(GlideSwap.weightAt(T0, start, DURATION, 0.8e18, 0.2e18), 0.8e18);
        assertEq(GlideSwap.weightAt(start, start, DURATION, 0.8e18, 0.2e18), 0.8e18);
        assertEq(GlideSwap.weightAt(start + DURATION / 2, start, DURATION, 0.8e18, 0.2e18), 0.5e18);
        assertEq(GlideSwap.weightAt(start + DURATION / 4, start, DURATION, 0.8e18, 0.2e18), 0.65e18);
        assertEq(GlideSwap.weightAt(start + DURATION, start, DURATION, 0.8e18, 0.2e18), 0.2e18);
        assertEq(GlideSwap.weightAt(start + 10 * DURATION, start, DURATION, 0.8e18, 0.2e18), 0.2e18);
        // ascending path
        assertEq(GlideSwap.weightAt(start + DURATION / 2, start, DURATION, 0.2e18, 0.8e18), 0.5e18);
    }

    function test_QuoteGlidesOverTime() public {
        uint40 start = T0 + 1 hours;
        ISwapVM.Order memory order = _ship(_program(0, start, 0.8e18, 0.2e18), 800e18, 200e18);

        // before start: weights 80/20 on 800/200 -> spot 1
        assertApproxEqRel(_spotAToB(order), 1e18, 0.001e18);

        // midway: weights 50/50 on 800/200 -> spot (200/0.5)/(800/0.5) = 0.25
        vm.warp(start + DURATION / 2);
        assertApproxEqRel(_spotAToB(order), 0.25e18, 0.001e18);

        // after end: weights 20/80 -> (200/0.8)/(800/0.2) = 0.0625
        vm.warp(start + DURATION + 1);
        assertApproxEqRel(_spotAToB(order), 0.0625e18, 0.001e18);
    }

    // ---- settlement ----

    function test_SwapMovesMakerWalletAndAquaBalances() public {
        ISwapVM.Order memory order = _ship(_program(0, T0 - 1, 0.5e18, 0.5e18), 1_000e18, 1_000e18);
        bytes32 orderHash = swapVM.hash(order);

        uint256 makerA = tokenA.balanceOf(maker);
        uint256 makerB = tokenB.balanceOf(maker);

        (uint256 amountIn, uint256 amountOut) = _swap(order, true, true, 10e18);
        assertEq(amountIn, 10e18);
        assertGt(amountOut, 0);

        assertEq(tokenA.balanceOf(maker), makerA + amountIn, "maker wallet A");
        assertEq(tokenB.balanceOf(maker), makerB - amountOut, "maker wallet B");
        assertEq(tokenB.balanceOf(address(taker)), amountOut, "taker got B");

        (uint256 aquaA, uint256 aquaB) = getAquaBalances(orderHash);
        assertEq(aquaA, 1_000e18 + amountIn);
        assertEq(aquaB, 1_000e18 - amountOut);
    }

    function test_ExactOut() public {
        ISwapVM.Order memory order = _ship(_program(0, T0 - 1, 0.7e18, 0.7e18), 1_000e18, 1_000e18);

        (uint256 qIn, uint256 qOut) = _quote(order, true, false, 50e18);
        assertEq(qOut, 50e18);

        (uint256 amountIn, uint256 amountOut) = _swap(order, true, false, 50e18);
        assertEq(amountIn, qIn);
        assertEq(amountOut, 50e18);

        // symmetry: exact-in with the same input never returns more than 50e18 (maker never loses on the round trip)
        (, uint256 backOut) = _quote(order, true, true, qIn);
        assertLe(backOut, 50e18 + 50e18 / 1e12 + 2);
    }

    function test_FeeAccruesInMakerAquaBalance() public {
        ISwapVM.Order memory noFee = _ship(_program(0, T0 - 1, 0.5e18, 0.5e18), 1_000e18, 1_000e18);
        ISwapVM.Order memory withFee = _ship(_program(0.003e7, T0 - 1, 0.5e18, 0.5e18), 1_000e18, 1_000e18);

        (, uint256 outNoFee) = _quote(noFee, true, true, 10e18);
        (uint256 amountIn, uint256 outWithFee) = _swap(withFee, true, true, 10e18);

        assertEq(amountIn, 10e18, "taker pays the full amount including fee");
        assertLt(outWithFee, outNoFee);
        // fee is charged on input: output approximately equals the no-fee output for 99.7% of the input
        (, uint256 outReduced) = _quote(noFee, true, true, 10e18 - 0.03e18);
        assertApproxEqRel(outWithFee, outReduced, 0.0001e18);

        // the whole input, fee included, lands in the maker's Aqua balance
        (uint256 aquaA,) = getAquaBalances(swapVM.hash(withFee));
        assertEq(aquaA, 1_000e18 + 10e18);
    }

    // ---- guards ----

    function test_RevertsOnEmptySide() public {
        ISwapVM.Order memory order = _ship(_program(0, T0 - 1, 0.5e18, 0.5e18), 1_000e18, 0);
        bytes memory data = abi.encodePacked(takerData(address(taker), true, true));
        ISwapVM v = swapVM.asView();
        vm.expectRevert(WeightedMath.WeightedMathZeroBalance.selector);
        v.quote(order, 1e18, data);
    }

    function test_RevertsOverMaxInRatio() public {
        ISwapVM.Order memory order = _ship(_program(0, T0 - 1, 0.5e18, 0.5e18), 1_000e18, 1_000e18);
        bytes memory data = abi.encodePacked(takerData(address(taker), true, true));
        ISwapVM v = swapVM.asView();
        vm.expectRevert(abi.encodeWithSelector(WeightedMath.WeightedMathMaxInRatio.selector, 400e18, 1_000e18));
        v.quote(order, 400e18, data);
    }

    function test_BuildRejectsBadParams() public {
        GlideSwapBuilder b = new GlideSwapBuilder();
        vm.expectRevert(GlideSwap.GlideSwapZeroDuration.selector);
        b.build(T0, 0, 0.5e18, 0.5e18);
        vm.expectRevert(abi.encodeWithSelector(GlideSwap.GlideSwapWeightOutOfRange.selector, uint64(0.995e18)));
        b.build(T0, 1, 0.995e18, 0.5e18);
        vm.expectRevert(abi.encodeWithSelector(GlideSwap.GlideSwapWeightOutOfRange.selector, uint64(0)));
        b.build(T0, 1, 0.5e18, 0);
        // boundaries are allowed
        b.build(T0, 1, 0.01e18, 0.99e18);
    }

    // ---- the product, as a test ----

    /// @dev Reference price is 1 B per A throughout. Maker starts 800 A / 200 B (value share 80%) and glides to 20%.
    ///      An arbitrageur keeps the pool at the reference price. The maker's value share must track the weight.
    function test_GlideSimulation_ValueShareTracksWeight() public {
        uint40 start = T0;
        uint24 feeBps = 0.003e7;
        ISwapVM.Order memory order = _ship(_program(feeBps, start, 0.8e18, 0.2e18), 800e18, 200e18);
        bytes32 orderHash = swapVM.hash(order);

        uint256 feesA;
        uint256 feesB;
        uint256 steps = 8;
        for (uint256 i = 1; i <= steps; i++) {
            vm.warp(start + DURATION * i / steps);
            uint256 wA = GlideSwap.weightAt(block.timestamp, start, DURATION, 0.8e18, 0.2e18);

            // arb: push spot back to 1 with 2%-of-reserve trades until within the fee band
            for (uint256 j = 0; j < 100; j++) {
                uint256 spot = _spotAToB(order);
                if (spot > 0.996e18 && spot < 1.004e18) break;
                (uint256 rA, uint256 rB) = getAquaBalances(orderHash);
                bool aToB = spot > ONE;                 // A buys more than 1 B: sell A to the maker
                uint256 amount = (aToB ? rA : rB) / 50;
                (uint256 amountIn,) = _swap(order, aToB, true, amount);
                if (aToB) feesA += amountIn * feeBps / 1e7; else feesB += amountIn * feeBps / 1e7;
            }

            (uint256 balA, uint256 balB) = getAquaBalances(orderHash);
            uint256 shareA = balA * ONE / (balA + balB);   // price is 1, so value share is the balance share
            assertApproxEqAbs(shareA, wA, 0.01e18, "value share off the glide path");
        }

        (uint256 endA, uint256 endB) = getAquaBalances(orderHash);
        assertApproxEqAbs(endA * ONE / (endA + endB), 0.2e18, 0.01e18);
        assertGt(feesA + feesB, 0, "maker earned no fees");
        emit log_named_decimal_uint("final A", endA, 18);
        emit log_named_decimal_uint("final B", endB, 18);
        emit log_named_decimal_uint("fees in A", feesA, 18);
        emit log_named_decimal_uint("fees in B", feesB, 18);
    }
}
