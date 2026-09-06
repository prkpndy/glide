// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Context } from "@1inch/swap-vm/src/libs/VM.sol";
import { Opcode } from "@1inch/swap-vm/src/libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "@1inch/swap-vm/src/libs/MemoryPtr.sol";
import { InstructionBuilder } from "@1inch/swap-vm/src/libs/InstructionBuilder.sol";
import { InstructionArgs } from "@1inch/swap-vm/src/libs/InstructionArgs.sol";

import { WeightedMath } from "../libs/WeightedMath.sol";

/// @notice GlideSwap opcode: a weighted constant-mean curve whose weights move linearly over time.
///   The weight of token A (the lower address) glides from `wA0` at `start` to `wA1` at `start + duration`
///   and is clamped outside that window. Token B weight is always `1e18 - wA`.
///   Balances come from the swap registers, so in Aqua mode the curve prices the maker's actual shipped balances.
/// @dev Encoding: [uint40 start, uint32 duration, uint64 wA0, uint64 wA1], weights in WAD
/// @dev Terminal curve instruction: does not call runLoop. Pair with FeeFlatIn placed before it for a maker fee.
/// @dev A weighted pool with time-varying weights is a Liquidity Bootstrapping Pool; at equilibrium the value share
///   of token A equals wA, so the maker's wallet composition tracks the glide path through arbitrage.
library GlideSwap {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;
    using InstructionBuilder for MemoryPtr;
    using MemoryPtrLib for MemoryPtr;

    error GlideSwapZeroDuration();
    error GlideSwapWeightOutOfRange(uint64 weight);

    Opcode constant opcode = Opcode._52;

    uint256 constant ONE = 1e18;

    function sizeOf(uint40, uint32, uint64, uint64) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 5 + 4 + 8 + 8;
    }

    function build(uint40 start, uint32 duration, uint64 wA0, uint64 wA1) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(start, duration, wA0, wA1)), start, duration, wA0, wA1).resolve();
    }

    function build(MemoryPtr ptrStart, uint40 start, uint32 duration, uint64 wA0, uint64 wA1) internal pure returns (MemoryPtr ptr) {
        require(duration > 0, GlideSwapZeroDuration());
        require(wA0 >= WeightedMath.MIN_WEIGHT && wA0 <= WeightedMath.MAX_WEIGHT, GlideSwapWeightOutOfRange(wA0));
        require(wA1 >= WeightedMath.MIN_WEIGHT && wA1 <= WeightedMath.MAX_WEIGHT, GlideSwapWeightOutOfRange(wA1));

        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(start, 5).push(duration, 4).push(wA0, 8).push(wA1, 8);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (uint40 start, uint32 duration, uint64 wA0, uint64 wA1) {
        start = args.at(0).asU40();
        duration = args.at(5).asU32();
        wA0 = args.at(9).asU64();
        wA1 = args.at(17).asU64();
    }

    /// @notice Token A weight at `timestamp`, linear between the endpoints and clamped outside the window
    function weightAt(uint256 timestamp, uint40 start, uint32 duration, uint64 wA0, uint64 wA1) internal pure returns (uint256) {
        if (timestamp <= start) return wA0;
        uint256 end = uint256(start) + duration;
        if (timestamp >= end) return wA1;

        uint256 elapsed = timestamp - start;
        if (wA1 >= wA0) return uint256(wA0) + (uint256(wA1 - wA0) * elapsed) / duration;
        return uint256(wA0) - (uint256(wA0 - wA1) * elapsed) / duration;
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        (uint40 start, uint32 duration, uint64 wA0, uint64 wA1) = parse(args);

        uint256 wA = weightAt(block.timestamp, start, duration, wA0, wA1);
        (uint256 wIn, uint256 wOut) = ctx.query.tokenIn < ctx.query.tokenOut
            ? (wA, ONE - wA)
            : (ONE - wA, wA);

        if (ctx.query.isExactIn) {
            ctx.swap.amountOut = WeightedMath.calcOutGivenIn(ctx.swap.balanceIn, wIn, ctx.swap.balanceOut, wOut, ctx.swap.amountIn);
        } else {
            ctx.swap.amountIn = WeightedMath.calcInGivenOut(ctx.swap.balanceIn, wIn, ctx.swap.balanceOut, wOut, ctx.swap.amountOut);
        }
    }
}
