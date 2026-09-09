// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

import { GlideLens } from "../src/periphery/GlideLens.sol";

/// @dev Shared readers for deployments/<chainId>.json and deployments/position-<chainId>.json
abstract contract Common is Script {
    struct Deployment {
        address aqua;
        address poolManager;
        address tokenA;
        address tokenB;
        address router;
        address lens;
        address hook;
        address swapRouter;
        uint24 poolFee;
        int24 tickSpacing;
    }

    function _deployment() internal view returns (Deployment memory d) {
        string memory j = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        d.aqua = vm.parseJsonAddress(j, ".aqua");
        d.poolManager = vm.parseJsonAddress(j, ".poolManager");
        d.tokenA = vm.parseJsonAddress(j, ".tokenA");
        d.tokenB = vm.parseJsonAddress(j, ".tokenB");
        d.router = vm.parseJsonAddress(j, ".router");
        d.lens = vm.parseJsonAddress(j, ".lens");
        d.hook = vm.parseJsonAddress(j, ".hook");
        d.swapRouter = vm.parseJsonAddress(j, ".swapRouter");
        d.poolFee = uint24(vm.parseJsonUint(j, ".poolFee"));
        d.tickSpacing = int24(vm.parseJsonInt(j, ".tickSpacing"));
    }

    function _poolKey(Deployment memory d) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(d.tokenA),
            currency1: Currency.wrap(d.tokenB),
            fee: d.poolFee,
            tickSpacing: d.tickSpacing,
            hooks: IHooks(d.hook)
        });
    }

    function _positionPath() internal view returns (string memory) {
        return string.concat("deployments/position-", vm.toString(block.chainid), ".json");
    }

    function _position() internal view returns (address maker, GlideLens.GlideParams memory p) {
        string memory j = vm.readFile(_positionPath());
        maker = vm.parseJsonAddress(j, ".maker");
        p.tokenA = vm.parseJsonAddress(j, ".params.tokenA");
        p.tokenB = vm.parseJsonAddress(j, ".params.tokenB");
        p.feeBps = uint24(vm.parseJsonUint(j, ".params.feeBps"));
        p.start = uint40(vm.parseJsonUint(j, ".params.start"));
        p.duration = uint32(vm.parseJsonUint(j, ".params.duration"));
        p.wA0 = uint64(vm.parseJsonUint(j, ".params.wA0"));
        p.wA1 = uint64(vm.parseJsonUint(j, ".params.wA1"));
        p.salt = uint64(vm.parseJsonUint(j, ".params.salt"));
    }
}
