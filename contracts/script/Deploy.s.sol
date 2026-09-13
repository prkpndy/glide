// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script, console } from "forge-std/Script.sol";
import { HookMiner } from "v4-periphery/test/shared/HookMiner.sol";

import { Hooks } from "v4-core/libraries/Hooks.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

import { GlideSwapVMRouter } from "../src/routers/GlideSwapVMRouter.sol";
import { GlideLens } from "../src/periphery/GlideLens.sol";
import { GlideHook } from "../src/hooks/GlideHook.sol";

/// @notice Deploys router, lens, hook (mined address), a PoolSwapTest router for demos, and initialises the
///         USDC/WETH Glide pool. Writes deployments/<chainId>.json.
/// @dev PRIVATE_KEY=... forge script script/Deploy.s.sol --rpc-url $RPC --broadcast
contract Deploy is Script {
    // Arachnid deterministic deployer, the CREATE2 factory forge scripts use for `new X{salt: s}()`
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 constant TICK_SPACING = 60;

    function run() external {
        address aqua = vm.envOr("AQUA", 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a);
        address weth = vm.envOr("WETH", 0x4200000000000000000000000000000000000006);
        address usdc = vm.envOr("USDC", 0x078D782b760474a361dDA0AF3839290b0EF57AD6);
        address pm = vm.envOr("POOL_MANAGER", 0x1F98400000000000000000000000000000000004);
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        uint160 flags = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG;

        // every deployment goes through the CREATE2 factory: deterministic addresses, and forge does not have to
        // match plain-CREATE initcode against artifacts (which mis-decoded the router's constructor args)
        bytes32 salt = keccak256(abi.encodePacked("glide", vm.envOr("DEPLOY_SALT", block.timestamp)));

        vm.startBroadcast(pk);

        GlideSwapVMRouter router = new GlideSwapVMRouter{ salt: salt }(aqua, weth, deployer);
        GlideLens lens = new GlideLens{ salt: salt }(ISwapVM(address(router)), IAqua(aqua));

        (address expectedHook, bytes32 hookSalt) = HookMiner.find(
            CREATE2_DEPLOYER, flags, type(GlideHook).creationCode, abi.encode(IPoolManager(pm), ISwapVM(address(router)))
        );
        GlideHook hook = new GlideHook{ salt: hookSalt }(IPoolManager(pm), ISwapVM(address(router)));
        require(address(hook) == expectedHook, "hook address mismatch");

        PoolSwapTest swapRouter = new PoolSwapTest{ salt: salt }(IPoolManager(pm));

        (address tokenA, address tokenB) = usdc < weth ? (usdc, weth) : (weth, usdc);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(tokenA),
            currency1: Currency.wrap(tokenB),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        IPoolManager(pm).initialize(key, SQRT_PRICE_1_1);

        vm.stopBroadcast();

        string memory j = "deployments";
        vm.serializeUint(j, "chainId", block.chainid);
        vm.serializeUint(j, "deployedAtBlock", block.number);
        vm.serializeAddress(j, "deployer", deployer);
        vm.serializeAddress(j, "aqua", aqua);
        vm.serializeAddress(j, "poolManager", pm);
        vm.serializeAddress(j, "weth", weth);
        vm.serializeAddress(j, "usdc", usdc);
        vm.serializeAddress(j, "tokenA", tokenA);
        vm.serializeAddress(j, "tokenB", tokenB);
        vm.serializeAddress(j, "router", address(router));
        vm.serializeAddress(j, "lens", address(lens));
        vm.serializeAddress(j, "hook", address(hook));
        vm.serializeAddress(j, "swapRouter", address(swapRouter));
        vm.serializeUint(j, "poolFee", 0);
        string memory out = vm.serializeInt(j, "tickSpacing", TICK_SPACING);
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(out, path);

        console.log("router    ", address(router));
        console.log("lens      ", address(lens));
        console.log("hook      ", address(hook));
        console.log("swapRouter", address(swapRouter));
        console.log("written   ", path);
    }
}
