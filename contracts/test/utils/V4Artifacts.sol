// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Vm } from "forge-std/Vm.sol";

/// @dev Deploys Uniswap v4's PoolManager from the artifact produced by `FOUNDRY_PROFILE=v4 forge build`.
///      PoolManager pins solc 0.8.26 and cannot share a via_ir compilation unit with SwapVM (solc 0.8.30).
library V4Artifacts {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function deployPoolManager(address owner) internal returns (address addr) {
        string memory json = vm.readFile("out-v4/PoolManager.sol/PoolManager.json");
        bytes memory creation = vm.parseJsonBytes(json, ".bytecode.object");
        bytes memory code = abi.encodePacked(creation, abi.encode(owner));
        assembly ("memory-safe") {
            addr := create(0, add(code, 0x20), mload(code))
        }
        require(addr != address(0), "PoolManager deploy failed; run FOUNDRY_PROFILE=v4 forge build");
    }
}
