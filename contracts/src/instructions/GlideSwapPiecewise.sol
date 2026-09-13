// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Context } from "@1inch/swap-vm/src/libs/VM.sol";
import { Opcode } from "@1inch/swap-vm/src/libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "@1inch/swap-vm/src/libs/MemoryPtr.sol";
import { InstructionBuilder } from "@1inch/swap-vm/src/libs/InstructionBuilder.sol";
import { InstructionArgs } from "@1inch/swap-vm/src/libs/InstructionArgs.sol";

import { GlideSwap } from "./GlideSwap.sol";
import { WeightedMath } from "../libs/WeightedMath.sol";

/// @notice GlideSwapPiecewise opcode: the same weighted curve as GlideSwap, with the token-A weight following a
///   piecewise-linear schedule instead of a single straight line. Lets a maker front-load, back-load, S-curve or
///   hold-then-move a conversion. Before `start` the first weight applies, after the last segment the last weight.
/// @dev Encoding: [uint40 start, uint64 w[0], (uint32 duration[i], uint64 w[i+1])...], `durations.length == weights.length - 1`
/// @dev Up to 20 segments fit in the 255-byte instruction argument limit.
library GlideSwapPiecewise {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;
    using InstructionBuilder for MemoryPtr;
    using MemoryPtrLib for MemoryPtr;

    error GlideSwapPiecewiseBadLengths();
    error GlideSwapPiecewiseZeroDuration();
    error GlideSwapPiecewiseWeightOutOfRange(uint64 weight);

    Opcode constant opcode = Opcode._55;

    uint256 constant HEADER = 5 + 8;
    uint256 constant SEGMENT = 4 + 8;

    function sizeOf(uint40, uint64[] memory weights, uint32[] memory) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + HEADER + (weights.length - 1) * SEGMENT;
    }

    function build(uint40 start, uint64[] memory weights, uint32[] memory durations) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(start, weights, durations)), start, weights, durations).resolve();
    }

    function build(MemoryPtr ptrStart, uint40 start, uint64[] memory weights, uint32[] memory durations) internal pure returns (MemoryPtr ptr) {
        require(weights.length >= 2 && durations.length + 1 == weights.length, GlideSwapPiecewiseBadLengths());

        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(start, 5).push(_checked(weights[0]), 8);
        for (uint256 i = 0; i < durations.length; i++) {
            require(durations[i] > 0, GlideSwapPiecewiseZeroDuration());
            ptr = ptr.push(durations[i], 4).push(_checked(weights[i + 1]), 8);
        }
        ptrStart.patchLength(ptr);
    }

    function _checked(uint64 w) private pure returns (uint64) {
        require(w >= WeightedMath.MIN_WEIGHT && w <= WeightedMath.MAX_WEIGHT, GlideSwapPiecewiseWeightOutOfRange(w));
        return w;
    }

    function segments(bytes calldata args) internal pure returns (uint256) {
        return (args.length - HEADER) / SEGMENT;
    }

    function parseStart(bytes calldata args) internal pure returns (uint40) {
        return args.at(0).asU40();
    }

    /// @dev weight at point `i`, 0 <= i <= segments
    function parseWeight(bytes calldata args, uint256 i) internal pure returns (uint64) {
        return i == 0 ? args.at(5).asU64() : args.at(HEADER + (i - 1) * SEGMENT + 4).asU64();
    }

    /// @dev duration of segment `i`, 0 <= i < segments
    function parseDuration(bytes calldata args, uint256 i) internal pure returns (uint32) {
        return args.at(HEADER + i * SEGMENT).asU32();
    }

    /// @notice Token A weight at `timestamp`: linear inside the active segment, clamped outside the schedule
    function weightAt(bytes calldata args, uint256 timestamp) internal pure returns (uint256) {
        uint40 start = parseStart(args);
        uint256 n = segments(args);
        if (timestamp <= start) return parseWeight(args, 0);

        uint256 t = timestamp - start;
        for (uint256 i = 0; i < n; i++) {
            uint256 dur = parseDuration(args, i);
            if (t <= dur) {
                uint256 w0 = parseWeight(args, i);
                uint256 w1 = parseWeight(args, i + 1);
                return w1 >= w0 ? w0 + ((w1 - w0) * t) / dur : w0 - ((w0 - w1) * t) / dur;
            }
            t -= dur;
        }
        return parseWeight(args, n);
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        GlideSwap.applyWeight(ctx, weightAt(args, block.timestamp));
    }
}
