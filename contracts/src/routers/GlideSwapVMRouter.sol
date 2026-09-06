// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Simulator } from "@1inch/solidity-utils/contracts/mixins/Simulator.sol";
import { SwapVM } from "@1inch/swap-vm/src/SwapVM.sol";
import { Context } from "@1inch/swap-vm/src/libs/VM.sol";

import { GlideOpcodes } from "../opcodes/GlideOpcodes.sol";

/// @title GlideSwapVMRouter
/// @notice AquaSwapVMRouter with the GlideSwap instruction added. Settles through the official Aqua registry.
contract GlideSwapVMRouter is Simulator, SwapVM, GlideOpcodes {
    constructor(address aqua, address weth, address owner) SwapVM(aqua, weth, owner, "GlideSwapVMRouter", "1.0.0") {}

    function _dispatch(Context memory ctx, uint256 opcode, bytes calldata args) internal override {
        _runOpcode(ctx, opcode, args);
    }
}
