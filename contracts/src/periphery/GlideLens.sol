// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { MakerTraitsLib } from "@1inch/swap-vm/src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import { FeeFlatIn } from "@1inch/swap-vm/src/instructions/FeeFlat.sol";
import { Salt } from "@1inch/swap-vm/src/instructions/Controls.sol";

import { GlideSwap } from "../instructions/GlideSwap.sol";
import { GlideSwapPiecewise } from "../instructions/GlideSwapPiecewise.sol";
import { WeightedMath } from "../libs/WeightedMath.sol";

/// @title GlideLens
/// @notice Stateless helpers so frontends and scripts never hand-pack SwapVM orders or taker traits.
contract GlideLens {
    uint256 internal constant ONE = 1e18;
    uint8 internal constant DOCKED = 0xff;

    struct GlideParams {
        address tokenA;     // lower address
        address tokenB;
        uint24 feeBps;      // 1e7 units, 0.003e7 = 0.30%
        uint40 start;
        uint32 duration;
        uint64 wA0;         // WAD weight of tokenA at start
        uint64 wA1;         // WAD weight of tokenA at end
        uint64 salt;
        // optional piecewise schedule: empty = straight line from wA0 to wA1 over `duration`;
        // otherwise weights[0] == wA0, weights[last] == wA1 and sum(durations) == duration
        uint64[] weights;
        uint32[] durations;
    }

    struct State {
        bool active;
        uint256 balanceA;
        uint256 balanceB;
        uint256 wA;
        uint256 spotBPerA;  // WAD, tokenB received per one tokenA at the margin (raw units)
    }

    error GlideLensTokensNotSorted();
    error GlideLensScheduleMismatch();

    ISwapVM public immutable ROUTER;
    IAqua public immutable AQUA;

    constructor(ISwapVM router, IAqua aqua) {
        ROUTER = router;
        AQUA = aqua;
    }

    // ---- maker side ----

    function program(GlideParams memory p) public pure returns (bytes memory) {
        return bytes.concat(
            p.feeBps > 0 ? FeeFlatIn.build(p.feeBps) : bytes(""),
            _curve(p),
            Salt.build(p.salt)
        );
    }

    function isPiecewise(GlideParams memory p) public pure returns (bool) {
        return p.weights.length > 0;
    }

    function _curve(GlideParams memory p) internal pure returns (bytes memory) {
        if (!isPiecewise(p)) return GlideSwap.build(p.start, p.duration, p.wA0, p.wA1);

        uint256 total;
        for (uint256 i = 0; i < p.durations.length; i++) total += p.durations[i];
        require(
            p.weights[0] == p.wA0 && p.weights[p.weights.length - 1] == p.wA1 && total == p.duration,
            GlideLensScheduleMismatch()
        );
        return GlideSwapPiecewise.build(p.start, p.weights, p.durations);
    }

    function buildOrder(address maker, GlideParams memory p) public pure returns (ISwapVM.Order memory) {
        require(p.tokenA < p.tokenB, GlideLensTokensNotSorted());
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            receiver: address(0),
            tokenA: p.tokenA,
            tokenB: p.tokenB,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: true,
            allowZeroAmountIn: false,
            hasPreTransferInHook: false,
            hasPostTransferInHook: false,
            hasPreTransferOutHook: false,
            hasPostTransferOutHook: false,
            preTransferInTarget: address(0),
            preTransferInData: "",
            postTransferInTarget: address(0),
            postTransferInData: "",
            preTransferOutTarget: address(0),
            preTransferOutData: "",
            postTransferOutTarget: address(0),
            postTransferOutData: "",
            program: program(p)
        }));
    }

    /// @notice Bytes to pass as `strategy` to `Aqua.ship(router, strategy, tokens, amounts)`
    function encodeShipStrategy(address maker, GlideParams memory p) external pure returns (bytes memory) {
        return abi.encode(buildOrder(maker, p));
    }

    function orderHash(address maker, GlideParams memory p) public view returns (bytes32) {
        return ROUTER.hash(buildOrder(maker, p));
    }

    /// @notice Start weight that makes the pool's spot price equal the market price. Values must be in one unit.
    function deriveStartWeight(uint256 valueA, uint256 valueB) external pure returns (uint64) {
        uint256 w = valueA * ONE / (valueA + valueB);
        if (w < WeightedMath.MIN_WEIGHT) w = WeightedMath.MIN_WEIGHT;
        if (w > WeightedMath.MAX_WEIGHT) w = WeightedMath.MAX_WEIGHT;
        return uint64(w);
    }

    // ---- taker side ----

    /// @notice Taker traits for a direct router swap. The router pulls tokenIn from the taker and pushes it to Aqua.
    /// @param threshold min amountOut for exact-in, max amountIn for exact-out; 0 disables
    /// @param to recipient, address(0) means the caller
    function takerData(bool isExactIn, bool aToB, uint256 threshold, address to, uint40 deadline) public pure returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: true,
            isAToB: aToB,
            allowPartialFill: false,
            threshold: threshold > 0 ? abi.encodePacked(bytes32(threshold)) : bytes(""),
            to: to,
            deadline: deadline,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: ""
        }));
    }

    function quote(ISwapVM.Order memory order, bool isExactIn, bool aToB, uint256 amount) public view returns (uint256 amountIn, uint256 amountOut) {
        (amountIn, amountOut,) = ROUTER.quote(order, amount, takerData(isExactIn, aToB, 0, address(0), 0));
    }

    function quote(address maker, GlideParams memory p, bool isExactIn, bool aToB, uint256 amount) external view returns (uint256 amountIn, uint256 amountOut) {
        return quote(buildOrder(maker, p), isExactIn, aToB, amount);
    }

    // ---- state ----

    function weightNow(GlideParams memory p) public view returns (uint256) {
        return weightAt(p, block.timestamp);
    }

    function weightAt(GlideParams memory p, uint256 timestamp) public view returns (uint256) {
        if (!isPiecewise(p)) return GlideSwap.weightAt(timestamp, p.start, p.duration, p.wA0, p.wA1);
        return this.piecewiseWeightAt(GlideSwapPiecewise.build(p.start, p.weights, p.durations), timestamp);
    }

    /// @dev external so the packed args can be read as calldata by the instruction's own parser
    function piecewiseWeightAt(bytes calldata curveInstruction, uint256 timestamp) external pure returns (uint256) {
        // skip the 2-byte [opcode, argsLength] header
        return GlideSwapPiecewise.weightAt(curveInstruction[2:], timestamp);
    }

    function state(address maker, GlideParams memory p) external view returns (State memory s) {
        bytes32 h = orderHash(maker, p);
        (uint248 balA, uint8 countA) = AQUA.rawBalances(maker, address(ROUTER), h, p.tokenA);
        (uint248 balB,) = AQUA.rawBalances(maker, address(ROUTER), h, p.tokenB);
        s.active = countA > 0 && countA != DOCKED;
        s.balanceA = balA;
        s.balanceB = balB;
        s.wA = weightNow(p);
        if (balA > 0 && balB > 0) {
            s.spotBPerA = WeightedMath.spotOutPerIn(balA, s.wA, balB, ONE - s.wA);
        }
    }
}
