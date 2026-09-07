// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { BeforeSwapDelta, toBeforeSwapDelta } from "v4-core/types/BeforeSwapDelta.sol";
import { ModifyLiquidityParams, SwapParams } from "v4-core/types/PoolOperation.sol";

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";

/// @title GlideHook
/// @notice Turns a Uniswap v4 pool into a doorway to a Glide position. The pool holds no liquidity: every swap is
///         taken from the PoolManager, filled against the maker's Aqua-backed SwapVM order, and settled back.
/// @dev Custom accounting via beforeSwapReturnDelta. Exact-in only. One route per pool. ERC20 currencies only.
/// @dev Flash accounting: the input is taken from the PoolManager's aggregate token float inside beforeSwap, before
///      the swapper settles; the returned delta moves that debt onto the swapper and the PoolManager's unlock check
///      forces repayment. This needs the PoolManager to hold at least amountIn of the input token, which is always
///      true on a live deployment and never true on a freshly deployed, empty PoolManager.
contract GlideHook is IHooks {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;
    using PoolIdLibrary for PoolKey;

    error GlideHookNotPoolManager();
    error GlideHookNotImplemented();
    error GlideHookExactInOnly();
    error GlideHookNoRoute();
    error GlideHookNotMaker();
    error GlideHookWrongHook();
    error GlideHookTokenMismatch();
    error GlideHookNoLiquidity();
    error GlideHookNativeNotSupported();

    event RouteRegistered(PoolId indexed poolId, address indexed maker, bytes32 indexed orderHash);
    event RouteCleared(PoolId indexed poolId, address indexed maker);
    event Routed(PoolId indexed poolId, address indexed sender, bool zeroForOne, uint256 amountIn, uint256 amountOut);

    struct Route {
        address maker;
        bytes order; // abi.encode(ISwapVM.Order)
    }

    IPoolManager public immutable POOL_MANAGER;
    ISwapVM public immutable ROUTER;

    mapping(PoolId => Route) internal _routes;

    modifier onlyPoolManager() {
        require(msg.sender == address(POOL_MANAGER), GlideHookNotPoolManager());
        _;
    }

    constructor(IPoolManager poolManager, ISwapVM router) {
        POOL_MANAGER = poolManager;
        ROUTER = router;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---- routes ----

    function route(PoolKey calldata key) external view returns (address maker, bytes memory order) {
        Route storage r = _routes[key.toId()];
        return (r.maker, r.order);
    }

    /// @notice Point a pool at a Glide order. The order's tokenA/tokenB must equal currency0/currency1.
    function registerRoute(PoolKey calldata key, ISwapVM.Order calldata order) external {
        require(msg.sender == order.maker, GlideHookNotMaker());
        require(address(key.hooks) == address(this), GlideHookWrongHook());
        require(!key.currency0.isAddressZero(), GlideHookNativeNotSupported());

        // order.data starts with [tokenA (20 bytes)][tokenB (20 bytes)], tokenA < tokenB, same ordering as currencies
        address tokenA = address(bytes20(order.data[:20]));
        address tokenB = address(bytes20(order.data[20:40]));
        require(tokenA == Currency.unwrap(key.currency0) && tokenB == Currency.unwrap(key.currency1), GlideHookTokenMismatch());

        PoolId id = key.toId();
        _routes[id] = Route({ maker: order.maker, order: abi.encode(order) });
        emit RouteRegistered(id, order.maker, ROUTER.hash(order));
    }

    function clearRoute(PoolKey calldata key) external {
        PoolId id = key.toId();
        require(msg.sender == _routes[id].maker, GlideHookNotMaker());
        delete _routes[id];
        emit RouteCleared(id, msg.sender);
    }

    // ---- the swap ----

    /// @param hookData optional abi.encode(uint256 minAmountOut)
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        require(params.amountSpecified < 0, GlideHookExactInOnly());
        Route storage r = _routes[key.toId()];
        require(r.maker != address(0), GlideHookNoRoute());

        (Currency cIn, Currency cOut) = params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 minOut = hookData.length >= 32 ? abi.decode(hookData, (uint256)) : 0;

        // 1. pull the swapper's input out of the PoolManager; this contract now owes the manager amountIn of cIn
        POOL_MANAGER.take(cIn, address(this), amountIn);

        // 2. fill against the Glide position, this contract is the SwapVM taker; router pulls cIn and pushes it to
        //    the maker via Aqua, Aqua pulls cOut from the maker's wallet to this contract
        IERC20(Currency.unwrap(cIn)).forceApprove(address(ROUTER), amountIn);
        ISwapVM.Order memory order = abi.decode(r.order, (ISwapVM.Order));
        (, uint256 amountOut,) = ROUTER.swap(order, amountIn, _takerData(params.zeroForOne, minOut));

        // 3. hand the output to the PoolManager so it can pay the swapper
        POOL_MANAGER.sync(cOut);
        IERC20(Currency.unwrap(cOut)).safeTransfer(address(POOL_MANAGER), amountOut);
        POOL_MANAGER.settle();

        emit Routed(key.toId(), sender, params.zeroForOne, amountIn, amountOut);

        // 4. consume the whole specified amount so the pool's own curve is skipped, and report the output
        return (
            IHooks.beforeSwap.selector,
            toBeforeSwapDelta(amountIn.toInt256().toInt128(), -amountOut.toInt256().toInt128()),
            0
        );
    }

    function _takerData(bool aToB, uint256 minOut) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(this),
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: true,
            isAToB: aToB,
            allowPartialFill: false,
            threshold: minOut > 0 ? abi.encodePacked(bytes32(minOut)) : bytes(""),
            to: address(0),
            deadline: 0,
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

    // ---- liquidity is never allowed in a Glide pool ----

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert GlideHookNoLiquidity();
    }

    // ---- unused hook points ----

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert GlideHookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert GlideHookNotImplemented();
    }

    function afterAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, BalanceDelta)
    {
        revert GlideHookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert GlideHookNotImplemented();
    }

    function afterRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, BalanceDelta)
    {
        revert GlideHookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert GlideHookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert GlideHookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert GlideHookNotImplemented();
    }
}
