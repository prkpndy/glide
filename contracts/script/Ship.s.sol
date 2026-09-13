// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

import { GlideLens } from "../src/periphery/GlideLens.sol";
import { GlideHook } from "../src/hooks/GlideHook.sol";
import { Common } from "./Common.s.sol";

/// @notice The maker ships a Glide position and points the Uniswap pool at it.
/// @dev MAKER_PK=... AMOUNT_A=3000000000 AMOUNT_B=5000000000000000000 PRICE_A=1e18 PRICE_B=3000e18 END_WEIGHT_A=0.7e18 \
///      DURATION=86400 FEE_BPS=30000 forge script script/Ship.s.sol --rpc-url $RPC --broadcast
///      PRICE_* are WAD USD per whole token and only serve to derive the start weight from the current value split.
contract Ship is Common {
    function _toUint256(uint64[] memory a) internal pure returns (uint256[] memory r) {
        r = new uint256[](a.length);
        for (uint256 i = 0; i < a.length; i++) r[i] = a[i];
    }

    function _toUint256(uint32[] memory a) internal pure returns (uint256[] memory r) {
        r = new uint256[](a.length);
        for (uint256 i = 0; i < a.length; i++) r[i] = a[i];
    }

    function _toUint64(uint256[] memory a) internal pure returns (uint64[] memory r) {
        r = new uint64[](a.length);
        for (uint256 i = 0; i < a.length; i++) r[i] = uint64(a[i]);
    }

    function _toUint32(uint256[] memory a) internal pure returns (uint32[] memory r) {
        r = new uint32[](a.length);
        for (uint256 i = 0; i < a.length; i++) r[i] = uint32(a[i]);
    }

    function run() external {
        Deployment memory d = _deployment();
        uint256 pk = vm.envUint("MAKER_PK");
        address maker = vm.addr(pk);

        uint256 amountA = vm.envUint("AMOUNT_A");
        uint256 amountB = vm.envUint("AMOUNT_B");
        uint256 valueA = amountA * vm.envUint("PRICE_A") / 10 ** IERC20Metadata(d.tokenA).decimals();
        uint256 valueB = amountB * vm.envUint("PRICE_B") / 10 ** IERC20Metadata(d.tokenB).decimals();

        GlideLens lens = GlideLens(d.lens);
        GlideLens.GlideParams memory p = GlideLens.GlideParams({
            tokenA: d.tokenA,
            tokenB: d.tokenB,
            feeBps: uint24(vm.envOr("FEE_BPS", uint256(30_000))),
            start: uint40(vm.envOr("START", block.timestamp)),
            duration: uint32(vm.envOr("DURATION", uint256(1 days))),
            wA0: lens.deriveStartWeight(valueA, valueB),
            wA1: uint64(vm.envUint("END_WEIGHT_A")),
            salt: uint64(vm.envOr("SALT", block.timestamp)),
            weights: new uint64[](0),
            durations: new uint32[](0)
        });
        // optional piecewise schedule: WEIGHTS="w0,w1,...,wn" (WAD) and DURATIONS="d1,...,dn" (seconds, sum == DURATION)
        if (bytes(vm.envOr("WEIGHTS", string(""))).length > 0) {
            p.weights = _toUint64(vm.envUint("WEIGHTS", ","));
            p.durations = _toUint32(vm.envUint("DURATIONS", ","));
            p.wA0 = p.weights[0];
            p.wA1 = p.weights[p.weights.length - 1];
        }
        ISwapVM.Order memory order = lens.buildOrder(maker, p);
        bytes32 orderHash = lens.orderHash(maker, p);

        address[] memory tokens = new address[](2);
        tokens[0] = d.tokenA;
        tokens[1] = d.tokenB;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amountA;
        amounts[1] = amountB;

        vm.startBroadcast(pk);
        if (IERC20(d.tokenA).allowance(maker, d.aqua) < amountA) IERC20(d.tokenA).approve(d.aqua, type(uint256).max);
        if (IERC20(d.tokenB).allowance(maker, d.aqua) < amountB) IERC20(d.tokenB).approve(d.aqua, type(uint256).max);
        bytes32 shipped = IAqua(d.aqua).ship(d.router, lens.encodeShipStrategy(maker, p), tokens, amounts);
        GlideHook(d.hook).registerRoute(_poolKey(d), order);
        vm.stopBroadcast();
        require(shipped == orderHash, "strategy hash mismatch");

        string memory pj = "params";
        vm.serializeAddress(pj, "tokenA", p.tokenA);
        vm.serializeAddress(pj, "tokenB", p.tokenB);
        vm.serializeUint(pj, "feeBps", p.feeBps);
        vm.serializeUint(pj, "start", p.start);
        vm.serializeUint(pj, "duration", p.duration);
        // large values are written as decimal strings so JavaScript readers do not lose precision
        vm.serializeString(pj, "wA0", vm.toString(p.wA0));
        vm.serializeString(pj, "wA1", vm.toString(p.wA1));
        vm.serializeString(pj, "salt", vm.toString(p.salt));
        vm.serializeUint(pj, "weights", _toUint256(p.weights));
        string memory paramsJson = vm.serializeUint(pj, "durations", _toUint256(p.durations));

        string memory j = "position";
        vm.serializeAddress(j, "maker", maker);
        vm.serializeBytes32(j, "orderHash", orderHash);
        vm.serializeString(j, "amountA", vm.toString(amountA));
        vm.serializeString(j, "amountB", vm.toString(amountB));
        vm.serializeString(j, "priceA", vm.toString(vm.envUint("PRICE_A")));
        vm.serializeString(j, "priceB", vm.toString(vm.envUint("PRICE_B")));
        string memory out = vm.serializeString(j, "params", paramsJson);
        vm.writeJson(out, _positionPath());

        console.log("shape     ", p.weights.length > 0 ? "piecewise" : "linear");
        console.log("maker     ", maker);
        console.log("orderHash ", vm.toString(orderHash));
        console.log("wA0       ", p.wA0);
        console.log("wA1       ", p.wA1);
        console.log("written   ", _positionPath());
    }
}
