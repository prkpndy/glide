// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { TickMath } from "v4-core/libraries/TickMath.sol";
import { SwapParams } from "v4-core/types/PoolOperation.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

import { GlideLens } from "../src/periphery/GlideLens.sol";
import { Common } from "./Common.s.sol";

/// @notice A taker swaps against the shipped position, either directly through the Glide router or through
///         Uniswap v4 (PoolManager -> GlideHook -> router -> Aqua).
/// @dev TAKER_PK=... A_TO_B=true AMOUNT_IN=300000000 VIA=direct|uniswap forge script script/Swap.s.sol --rpc-url $RPC --broadcast
contract Swap is Common {
    function run() external {
        Deployment memory d = _deployment();
        (address maker, GlideLens.GlideParams memory p) = _position();
        uint256 pk = vm.envUint("TAKER_PK");
        address taker = vm.addr(pk);
        bool aToB = vm.envOr("A_TO_B", true);
        uint256 amountIn = vm.envUint("AMOUNT_IN");
        bool viaUniswap = keccak256(bytes(vm.envOr("VIA", string("direct")))) == keccak256("uniswap");

        GlideLens lens = GlideLens(d.lens);
        ISwapVM.Order memory order = lens.buildOrder(maker, p);
        (, uint256 expectedOut) = lens.quote(order, true, aToB, amountIn);
        uint256 minOut = expectedOut * 995 / 1000;
        (address tokenIn, address tokenOut) = aToB ? (d.tokenA, d.tokenB) : (d.tokenB, d.tokenA);

        uint256 makerInBefore = IERC20(tokenIn).balanceOf(maker);
        uint256 makerOutBefore = IERC20(tokenOut).balanceOf(maker);
        uint256 takerOutBefore = IERC20(tokenOut).balanceOf(taker);

        vm.startBroadcast(pk);
        if (viaUniswap) {
            IERC20(tokenIn).approve(d.swapRouter, amountIn);
            PoolSwapTest(d.swapRouter).swap(
                _poolKey(d),
                SwapParams({
                    zeroForOne: aToB,
                    amountSpecified: -int256(amountIn),
                    sqrtPriceLimitX96: aToB ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
                abi.encode(minOut)
            );
        } else {
            IERC20(tokenIn).approve(d.router, amountIn);
            ISwapVM(d.router).swap(order, amountIn, lens.takerData(true, aToB, minOut, address(0), 0));
        }
        vm.stopBroadcast();

        console.log(viaUniswap ? "via Uniswap v4" : "direct via router");
        console.log("amountIn        ", amountIn);
        console.log("quoted out      ", expectedOut);
        console.log("taker received  ", IERC20(tokenOut).balanceOf(taker) - takerOutBefore);
        console.log("maker wallet in +", IERC20(tokenIn).balanceOf(maker) - makerInBefore);
        console.log("maker wallet out-", makerOutBefore - IERC20(tokenOut).balanceOf(maker));
    }
}
