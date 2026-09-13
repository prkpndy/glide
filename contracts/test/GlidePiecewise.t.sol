// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { AquaSwapVMTest } from "@1inch/swap-vm/test/base/AquaSwapVMTest.sol";
import { CoreInvariants } from "@1inch/swap-vm/test/invariants/CoreInvariants.t.sol";
import { SwapVM } from "@1inch/swap-vm/src/SwapVM.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { FeeFlatIn } from "@1inch/swap-vm/src/instructions/FeeFlat.sol";
import { Salt } from "@1inch/swap-vm/src/instructions/Controls.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { GlideSwapVMRouter } from "../src/routers/GlideSwapVMRouter.sol";
import { GlideSwap } from "../src/instructions/GlideSwap.sol";
import { GlideSwapPiecewise } from "../src/instructions/GlideSwapPiecewise.sol";
import { GlideLens } from "../src/periphery/GlideLens.sol";

/// @dev External wrappers: build-time reverts and calldata-based weightAt
contract PiecewiseHarness {
    function build(uint40 start, uint64[] memory w, uint32[] memory d) external pure returns (bytes memory) {
        return GlideSwapPiecewise.build(start, w, d);
    }

    function weightAt(bytes calldata instruction, uint256 t) external pure returns (uint256) {
        return GlideSwapPiecewise.weightAt(instruction[2:], t);
    }
}

contract GlidePiecewiseTest is AquaSwapVMTest, CoreInvariants {
    uint40 constant T0 = 1_800_000_000;

    PiecewiseHarness h;
    GlideLens lens;

    // 0.8 -> 0.5 in 6h, hold 0.5 for 6h, 0.5 -> 0.2 in 12h
    uint64[] W = [uint64(0.8e18), uint64(0.5e18), uint64(0.5e18), uint64(0.2e18)];
    uint32[] D = [uint32(6 hours), uint32(6 hours), uint32(12 hours)];

    function setUp() public override {
        vm.warp(T0);
        super.setUp();
        h = new PiecewiseHarness();
        lens = new GlideLens(ISwapVM(address(swapVM)), aqua);
    }

    function _deployRouter() internal override returns (SwapVM) {
        return new GlideSwapVMRouter(address(aqua), address(0), address(this));
    }

    function _executeSwap(SwapVM _swapVM, ISwapVM.Order memory order, address tokenIn, address, uint256 amount, bytes memory data)
        internal
        override
        returns (uint256 amountIn, uint256 amountOut)
    {
        (uint256 quotedIn,,) = _swapVM.asView().quote(order, amount, data);
        TokenMock(tokenIn).mint(address(taker), quotedIn);
        (amountIn, amountOut) = taker.swap(order, amount, data);
    }

    function _ship(bytes memory curve, uint256 balA, uint256 balB) internal returns (ISwapVM.Order memory order) {
        order = createStrategy(bytes.concat(FeeFlatIn.build(0.003e7), curve, Salt.build(abi.encodePacked(vm.randomUint()))));
        tokenA.mint(maker, balA);
        tokenB.mint(maker, balB);
        shipStrategy(order, tokenA, tokenB, balA, balB);
    }

    function _spotAToB(ISwapVM.Order memory order) internal view returns (uint256) {
        SwapProgram memory sp = SwapProgram({ amount: 1e12, taker: taker, tokenA: tokenA, tokenB: tokenB, zeroForOne: true, isExactIn: true });
        (uint256 aIn, uint256 bOut) = quote(sp, order);
        return bOut * ONE / aIn;
    }

    // ---- schedule ----

    function test_WeightAt_Schedule() public view {
        bytes memory ins = GlideSwapPiecewise.build(T0, W, D);
        assertEq(h.weightAt(ins, T0 - 1), 0.8e18, "before start");
        assertEq(h.weightAt(ins, T0), 0.8e18, "at start");
        assertEq(h.weightAt(ins, T0 + 3 hours), 0.65e18, "half of segment 1");
        assertEq(h.weightAt(ins, T0 + 6 hours), 0.5e18, "end of segment 1");
        assertEq(h.weightAt(ins, T0 + 9 hours), 0.5e18, "inside the hold");
        assertEq(h.weightAt(ins, T0 + 12 hours), 0.5e18, "end of hold");
        assertEq(h.weightAt(ins, T0 + 18 hours), 0.35e18, "half of segment 3");
        assertEq(h.weightAt(ins, T0 + 24 hours), 0.2e18, "end");
        assertEq(h.weightAt(ins, T0 + 240 hours), 0.2e18, "after end");
    }

    function test_SingleSegmentMatchesLinearOpcode() public {
        uint64[] memory w = new uint64[](2);
        w[0] = 0.8e18;
        w[1] = 0.2e18;
        uint32[] memory d = new uint32[](1);
        d[0] = 1 days;
        ISwapVM.Order memory piecewise = _ship(GlideSwapPiecewise.build(T0, w, d), 800e18, 200e18);
        ISwapVM.Order memory linear = _ship(GlideSwap.build(T0, 1 days, 0.8e18, 0.2e18), 800e18, 200e18);

        for (uint256 t = 0; t <= 30 hours; t += 5 hours) {
            vm.warp(T0 + t);
            assertEq(_spotAToB(piecewise), _spotAToB(linear), "same quotes as the linear opcode");
        }
    }

    function test_QuotesFollowTheHold() public {
        ISwapVM.Order memory order = _ship(GlideSwapPiecewise.build(T0, W, D), 800e18, 200e18);
        vm.warp(T0 + 7 hours);
        uint256 s1 = _spotAToB(order);
        vm.warp(T0 + 11 hours);
        assertEq(_spotAToB(order), s1, "price does not move during the hold");
        vm.warp(T0 + 13 hours);
        assertLt(_spotAToB(order), s1, "and moves again after it");
    }

    function test_BuildValidation() public {
        uint64[] memory w = new uint64[](2);
        w[0] = 0.5e18;
        w[1] = 0.5e18;
        uint32[] memory d = new uint32[](1);
        d[0] = 1;

        uint32[] memory dBad = new uint32[](2);
        vm.expectRevert(GlideSwapPiecewise.GlideSwapPiecewiseBadLengths.selector);
        h.build(T0, w, dBad);

        uint32[] memory dZero = new uint32[](1);
        vm.expectRevert(GlideSwapPiecewise.GlideSwapPiecewiseZeroDuration.selector);
        h.build(T0, w, dZero);

        w[1] = 0.999e18;
        vm.expectRevert(abi.encodeWithSelector(GlideSwapPiecewise.GlideSwapPiecewiseWeightOutOfRange.selector, uint64(0.999e18)));
        h.build(T0, w, d);

        // 20 segments fit, 21 do not
        uint64[] memory w20 = new uint64[](21);
        uint32[] memory d20 = new uint32[](20);
        for (uint256 i = 0; i < 21; i++) w20[i] = 0.5e18;
        for (uint256 i = 0; i < 20; i++) d20[i] = 1;
        h.build(T0, w20, d20);
        uint64[] memory w21 = new uint64[](22);
        uint32[] memory d21 = new uint32[](21);
        for (uint256 i = 0; i < 22; i++) w21[i] = 0.5e18;
        for (uint256 i = 0; i < 21; i++) d21[i] = 1;
        vm.expectRevert();
        h.build(T0, w21, d21);
    }

    // ---- lens ----

    function test_LensBuildsPiecewiseAndReportsWeight() public {
        GlideLens.GlideParams memory p = GlideLens.GlideParams({
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            feeBps: 0.003e7,
            start: T0,
            duration: 1 days,
            wA0: 0.8e18,
            wA1: 0.2e18,
            salt: 1,
            weights: W,
            durations: D
        });
        assertTrue(lens.isPiecewise(p));
        assertEq(lens.weightAt(p, T0 + 9 hours), 0.5e18);
        assertEq(lens.weightAt(p, T0 + 18 hours), 0.35e18);

        // the lens-built order quotes like a hand-built program at the same time
        ISwapVM.Order memory viaLens = lens.buildOrder(maker, p);
        tokenA.mint(maker, 800e18);
        tokenB.mint(maker, 200e18);
        shipStrategy(viaLens, tokenA, tokenB, 800e18, 200e18);
        vm.warp(T0 + 18 hours);
        (, uint256 out) = lens.quote(viaLens, true, true, 1e18);
        assertGt(out, 0);
        assertApproxEqRel(lens.state(maker, p).wA, 0.35e18, 1e12);

        // schedule must agree with the endpoints and the total duration
        p.wA1 = 0.3e18;
        vm.expectRevert(GlideLens.GlideLensScheduleMismatch.selector);
        lens.program(p);
    }

    // ---- invariants inside a segment and inside the hold ----

    function test_Invariants_InsideSegmentAndHold() public {
        ISwapVM.Order memory order = _ship(GlideSwapPiecewise.build(T0, W, D), 800e18, 200e18);

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 0.1e18;
        amounts[1] = 1e18;
        amounts[2] = 5e18;
        InvariantConfig memory cfg = createInvariantConfig(amounts, 1e9);
        cfg.additivityTolerance = 1e9;
        cfg.exactInTakerData = abi.encodePacked(takerData(address(taker), true, true));
        cfg.exactOutTakerData = abi.encodePacked(takerData(address(taker), false, true));

        vm.warp(T0 + 3 hours);
        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), cfg);
        vm.warp(T0 + 9 hours);
        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), cfg);
    }
}
