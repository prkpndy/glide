// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/// @title WeightedMath
/// @notice Constant-mean swap math: balanceA^wA * balanceB^wB = k. Every rounding step favours the maker.
/// @dev Formula structure and rounding directions follow Balancer V2 WeightedMath. The fixed-point power comes from
///      solady, which is an approximation with no rounding direction guarantee, so every power is bumped upwards by
///      MAX_POW_RELATIVE_ERROR (the same constant Balancer uses) before it is applied.
library WeightedMath {
    uint256 internal constant ONE = 1e18;

    /// @dev Relative bump applied to every power result, 1e-14
    uint256 internal constant MAX_POW_RELATIVE_ERROR = 10_000;

    /// @dev Largest single-trade size relative to the reserve, bounds pow error and keeps the curve well-conditioned
    uint256 internal constant MAX_IN_RATIO = 0.3e18;
    uint256 internal constant MAX_OUT_RATIO = 0.3e18;

    uint256 internal constant MIN_WEIGHT = 0.01e18;
    uint256 internal constant MAX_WEIGHT = 0.99e18;

    error WeightedMathZeroBalance();
    error WeightedMathMaxInRatio(uint256 amountIn, uint256 balanceIn);
    error WeightedMathMaxOutRatio(uint256 amountOut, uint256 balanceOut);

    /// @notice Output for a given input. Rounds down.
    /// @dev amountOut = balanceOut * (1 - (balanceIn / (balanceIn + amountIn)) ^ (weightIn / weightOut))
    function calcOutGivenIn(
        uint256 balanceIn,
        uint256 weightIn,
        uint256 balanceOut,
        uint256 weightOut,
        uint256 amountIn
    ) internal pure returns (uint256 amountOut) {
        require(balanceIn > 0 && balanceOut > 0, WeightedMathZeroBalance());
        require(amountIn <= FixedPointMathLib.mulWad(balanceIn, MAX_IN_RATIO), WeightedMathMaxInRatio(amountIn, balanceIn));

        // base <= 1, rounded up -> power larger -> output smaller
        uint256 base = FixedPointMathLib.divWadUp(balanceIn, balanceIn + amountIn);
        // base < 1 so a smaller exponent gives a larger power -> round exponent down
        uint256 exponent = FixedPointMathLib.divWad(weightIn, weightOut);
        uint256 power = powUp(base, exponent);
        if (power >= ONE) return 0;

        amountOut = FixedPointMathLib.mulWad(balanceOut, ONE - power);
    }

    /// @notice Input for a given output. Rounds up.
    /// @dev amountIn = balanceIn * ((balanceOut / (balanceOut - amountOut)) ^ (weightOut / weightIn) - 1)
    function calcInGivenOut(
        uint256 balanceIn,
        uint256 weightIn,
        uint256 balanceOut,
        uint256 weightOut,
        uint256 amountOut
    ) internal pure returns (uint256 amountIn) {
        require(balanceIn > 0 && balanceOut > 0, WeightedMathZeroBalance());
        require(amountOut <= FixedPointMathLib.mulWad(balanceOut, MAX_OUT_RATIO), WeightedMathMaxOutRatio(amountOut, balanceOut));

        // base >= 1, rounded up -> power larger -> input larger
        uint256 base = FixedPointMathLib.divWadUp(balanceOut, balanceOut - amountOut);
        // base > 1 so a larger exponent gives a larger power -> round exponent up
        uint256 exponent = FixedPointMathLib.divWadUp(weightOut, weightIn);
        uint256 power = powUp(base, exponent);

        amountIn = FixedPointMathLib.mulWadUp(balanceIn, power - ONE);
    }

    /// @notice Marginal price: units of tokenOut received per one unit of tokenIn, WAD.
    /// @dev (balanceOut / weightOut) / (balanceIn / weightIn)
    function spotOutPerIn(
        uint256 balanceIn,
        uint256 weightIn,
        uint256 balanceOut,
        uint256 weightOut
    ) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(balanceOut * weightIn, ONE, balanceIn * weightOut);
    }

    /// @notice x^y in WAD, rounded up with a relative safety margin.
    function powUp(uint256 x, uint256 y) internal pure returns (uint256) {
        if (y == 0) return ONE;
        if (x == 0) return 0;
        if (x == ONE) return ONE;
        uint256 raw = uint256(FixedPointMathLib.powWad(int256(x), int256(y)));
        uint256 maxError = FixedPointMathLib.mulWadUp(raw, MAX_POW_RELATIVE_ERROR) + 1;
        return raw + maxError;
    }
}
