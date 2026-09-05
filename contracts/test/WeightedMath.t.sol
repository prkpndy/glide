// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

import { WeightedMath } from "../src/libs/WeightedMath.sol";

/// @dev External wrappers so reverts can be asserted
contract WeightedMathHarness {
    function outGivenIn(uint256 bIn, uint256 wIn, uint256 bOut, uint256 wOut, uint256 aIn) external pure returns (uint256) {
        return WeightedMath.calcOutGivenIn(bIn, wIn, bOut, wOut, aIn);
    }

    function inGivenOut(uint256 bIn, uint256 wIn, uint256 bOut, uint256 wOut, uint256 aOut) external pure returns (uint256) {
        return WeightedMath.calcInGivenOut(bIn, wIn, bOut, wOut, aOut);
    }
}

contract WeightedMathTest is Test {
    uint256 constant ONE = 1e18;
    uint256 constant MIN_BAL = 1e6;
    uint256 constant MAX_BAL = 1e30;

    WeightedMathHarness h;

    function setUp() public {
        h = new WeightedMathHarness();
    }

    // ---- reference implementations (no maker-favouring rounding) ----

    function _refOut(uint256 bIn, uint256 wIn, uint256 bOut, uint256 wOut, uint256 aIn) internal pure returns (uint256) {
        uint256 base = FixedPointMathLib.divWad(bIn, bIn + aIn);
        uint256 exp = FixedPointMathLib.divWad(wIn, wOut);
        uint256 p = uint256(FixedPointMathLib.powWad(int256(base), int256(exp)));
        if (p >= ONE) return 0;
        return FixedPointMathLib.mulWad(bOut, ONE - p);
    }

    function _refIn(uint256 bIn, uint256 wIn, uint256 bOut, uint256 wOut, uint256 aOut) internal pure returns (uint256) {
        uint256 base = FixedPointMathLib.divWad(bOut, bOut - aOut);
        uint256 exp = FixedPointMathLib.divWad(wOut, wIn);
        uint256 p = uint256(FixedPointMathLib.powWad(int256(base), int256(exp)));
        return FixedPointMathLib.mulWad(bIn, p - ONE);
    }

    /// @dev wA * ln(bA) + wB * ln(bB), a monotone transform of the invariant k
    function _logK(uint256 bA, uint256 wA, uint256 bB, uint256 wB) internal pure returns (int256) {
        return FixedPointMathLib.lnWad(int256(bA)) * int256(wA) / int256(ONE)
             + FixedPointMathLib.lnWad(int256(bB)) * int256(wB) / int256(ONE);
    }

    function _params(uint256 bIn, uint256 bOut, uint256 wIn) internal pure returns (uint256, uint256, uint256, uint256) {
        bIn = bound(bIn, MIN_BAL, MAX_BAL);
        bOut = bound(bOut, MIN_BAL, MAX_BAL);
        wIn = bound(wIn, WeightedMath.MIN_WEIGHT, WeightedMath.MAX_WEIGHT);
        return (bIn, bOut, wIn, ONE - wIn);
    }

    // ---- exact in ----

    function testFuzz_OutGivenIn_NeverBeatsReference(uint256 bIn, uint256 bOut, uint256 wIn, uint256 aIn) public pure {
        uint256 wOut;
        (bIn, bOut, wIn, wOut) = _params(bIn, bOut, wIn);
        aIn = bound(aIn, 1, FixedPointMathLib.mulWad(bIn, WeightedMath.MAX_IN_RATIO));

        uint256 ours = WeightedMath.calcOutGivenIn(bIn, wIn, bOut, wOut, aIn);
        uint256 ref = _refOut(bIn, wIn, bOut, wOut, aIn);

        assertLe(ours, ref, "maker overpaid vs reference");
        // bump is 1e-14 of the power, i.e. up to bOut * 1e-14, plus rounding dust
        assertLe(ref - ours, bOut / 1e13 + 2, "rounding loss too large");
    }

    function testFuzz_OutGivenIn_InvariantNeverDecreases(uint256 bIn, uint256 bOut, uint256 wIn, uint256 aIn) public pure {
        uint256 wOut;
        (bIn, bOut, wIn, wOut) = _params(bIn, bOut, wIn);
        aIn = bound(aIn, 1, FixedPointMathLib.mulWad(bIn, WeightedMath.MAX_IN_RATIO));

        uint256 aOut = WeightedMath.calcOutGivenIn(bIn, wIn, bOut, wOut, aIn);

        int256 before = _logK(bIn, wIn, bOut, wOut);
        int256 post = _logK(bIn + aIn, wIn, bOut - aOut, wOut);
        assertGe(post + 1e6, before, "invariant decreased");
    }

    function testFuzz_OutGivenIn_Concave(uint256 bIn, uint256 bOut, uint256 wIn, uint256 a1, uint256 a2) public pure {
        uint256 wOut;
        (bIn, bOut, wIn, wOut) = _params(bIn, bOut, wIn);
        uint256 maxIn = FixedPointMathLib.mulWad(bIn, WeightedMath.MAX_IN_RATIO);
        a1 = bound(a1, 1, maxIn / 2);
        a2 = bound(a2, 1, maxIn / 2);

        uint256 split = WeightedMath.calcOutGivenIn(bIn, wIn, bOut, wOut, a1) + WeightedMath.calcOutGivenIn(bIn, wIn, bOut, wOut, a2);
        uint256 single = WeightedMath.calcOutGivenIn(bIn, wIn, bOut, wOut, a1 + a2);
        // two independent trades from the same reserves always get at least as much as one combined trade;
        // the split pays the 1e-14 power bump twice, the single trade once
        assertLe(single, split + bOut / 1e13 + 4, "curve not concave");
    }

    // ---- exact out ----

    function testFuzz_InGivenOut_NeverBeatsReference(uint256 bIn, uint256 bOut, uint256 wIn, uint256 aOut) public pure {
        uint256 wOut;
        (bIn, bOut, wIn, wOut) = _params(bIn, bOut, wIn);
        aOut = bound(aOut, 1, FixedPointMathLib.mulWad(bOut, WeightedMath.MAX_OUT_RATIO));

        uint256 ours = WeightedMath.calcInGivenOut(bIn, wIn, bOut, wOut, aOut);
        uint256 ref = _refIn(bIn, wIn, bOut, wOut, aOut);

        assertGe(ours, ref, "maker undercharged vs reference");
        // power can be up to ~1.43^99 with extreme weights; bound the loss relative to the reference input instead
        assertLe(ours - ref, ref / 1e12 + bIn / 1e13 + 2, "rounding loss too large");
    }

    function testFuzz_InGivenOut_InvariantNeverDecreases(uint256 bIn, uint256 bOut, uint256 wIn, uint256 aOut) public pure {
        uint256 wOut;
        (bIn, bOut, wIn, wOut) = _params(bIn, bOut, wIn);
        aOut = bound(aOut, 1, FixedPointMathLib.mulWad(bOut, WeightedMath.MAX_OUT_RATIO));

        uint256 aIn = WeightedMath.calcInGivenOut(bIn, wIn, bOut, wOut, aOut);

        int256 before = _logK(bIn, wIn, bOut, wOut);
        int256 post = _logK(bIn + aIn, wIn, bOut - aOut, wOut);
        assertGe(post + 1e6, before, "invariant decreased");
    }

    // ---- round trip ----

    function testFuzz_RoundTrip(uint256 bIn, uint256 bOut, uint256 wIn, uint256 aIn) public pure {
        uint256 wOut;
        (bIn, bOut, wIn, wOut) = _params(bIn, bOut, wIn);
        aIn = bound(aIn, 1e3, FixedPointMathLib.mulWad(bIn, WeightedMath.MAX_IN_RATIO));

        uint256 aOut = WeightedMath.calcOutGivenIn(bIn, wIn, bOut, wOut, aIn);
        vm.assume(aOut > 0 && aOut <= FixedPointMathLib.mulWad(bOut, WeightedMath.MAX_OUT_RATIO));

        uint256 aInBack = WeightedMath.calcInGivenOut(bIn, wIn, bOut, wOut, aOut);
        uint256 diff = aInBack > aIn ? aInBack - aIn : aIn - aInBack;
        // the exact-in leg under-delivers by up to bOut*1e-14, which at extreme weight ratios is worth up to bIn*1e-12 of input;
        // on top of that, one wei of output granularity is worth (bIn*wOut)/(bOut*wIn) of input at the spot price
        uint256 oneWeiOut = bIn * wOut / (bOut * wIn) + 1;
        assertLe(diff, aIn / 1e12 + bIn / 1e11 + 2 * oneWeiOut + 2, "round trip drift");
    }

    // ---- anchors ----

    function test_FiftyFifty_IsConstantProduct() public pure {
        uint256 bIn = 1_000e18;
        uint256 bOut = 2_000e18;
        uint256 aIn = 100e18;
        uint256 xyc = aIn * bOut / (bIn + aIn);
        uint256 ours = WeightedMath.calcOutGivenIn(bIn, 0.5e18, bOut, 0.5e18, aIn);
        assertLe(ours, xyc);
        assertLe(xyc - ours, bOut / 1e13 + 2);
    }

    function test_SpotPrice_EqualsWeightRatio() public pure {
        // 80/20 balances with 80/20 weights price 1:1
        assertEq(WeightedMath.spotOutPerIn(800e18, 0.8e18, 200e18, 0.2e18), 1e18);
        // 50/50 balances with 80/20 weights: A is "over-weighted" so A is cheap in B terms
        assertEq(WeightedMath.spotOutPerIn(500e18, 0.8e18, 500e18, 0.2e18), 4e18);
    }

    function test_TinyTrade_RoundsToZeroNotAgainstMaker() public pure {
        uint256 out = WeightedMath.calcOutGivenIn(1_000e18, 0.5e18, 1_000e18, 0.5e18, 1);
        assertEq(out, 0);
    }

    function test_Reverts() public {
        vm.expectRevert(WeightedMath.WeightedMathZeroBalance.selector);
        h.outGivenIn(0, 0.5e18, 1e18, 0.5e18, 1);

        vm.expectRevert(WeightedMath.WeightedMathZeroBalance.selector);
        h.inGivenOut(1e18, 0.5e18, 0, 0.5e18, 1);

        vm.expectRevert(abi.encodeWithSelector(WeightedMath.WeightedMathMaxInRatio.selector, 0.31e18, 1e18));
        h.outGivenIn(1e18, 0.5e18, 1e18, 0.5e18, 0.31e18);

        vm.expectRevert(abi.encodeWithSelector(WeightedMath.WeightedMathMaxOutRatio.selector, 0.31e18, 1e18));
        h.inGivenOut(1e18, 0.5e18, 1e18, 0.5e18, 0.31e18);
    }
}
