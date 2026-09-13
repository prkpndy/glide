// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Context } from "@1inch/swap-vm/src/libs/VM.sol";
import { AquaOpcodes } from "@1inch/swap-vm/src/opcodes/AquaOpcodes.sol";
import { Opcode, OpcodeOps } from "@1inch/swap-vm/src/libs/OpcodeList.sol";

import { GlideSwap } from "../instructions/GlideSwap.sol";
import { GlideSwapPiecewise } from "../instructions/GlideSwapPiecewise.sol";

/// @notice The stock Aqua instruction set plus GlideSwap and GlideSwapPiecewise
contract GlideOpcodes is AquaOpcodes {
    using OpcodeOps for Opcode;

    function _runOpcode(Context memory ctx, uint256 opcode, bytes calldata args) internal virtual override {
        if (opcode == GlideSwap.opcode.asU8()) GlideSwap.exec(ctx, args);
        else if (opcode == GlideSwapPiecewise.opcode.asU8()) GlideSwapPiecewise.exec(ctx, args);
        else super._runOpcode(ctx, opcode, args);
    }
}
