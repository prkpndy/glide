# Glide: Technical Design

Companion to `02-product-design.md`. Everything here was checked against the actual `1inch/swap-vm`, `1inch/aqua`, and `Uniswap/v4-core` sources. File and function names below are the real ones.

---

## 0. Decisions made in this doc

| Decision | Choice | Why |
|---|---|---|
| Curve | Weighted constant-mean (Balancer-style), weights move linearly over time | This is exactly a Liquidity Bootstrapping Pool, a known-safe design. Equilibrium value share equals the weight, which is the product promise. |
| Where the curve lives | One new SwapVM instruction, `GlideSwap`, in the curve bank at `Opcode._52` | Stock SwapVM has no weighted curve and no way to pass a weight between instructions, so weight schedule and curve are one opcode. |
| Router | New `GlideSwapVMRouter` = `SwapVM` + all `AquaOpcodes` + `GlideSwap` | Matches 1inch's "redeploy a modified router" allowance. Official Aqua registry is used unchanged. |
| Balance source | Aqua mode (`useAquaInsteadOfSignature = true`) | Balances come from `Aqua.safeBalances`, so the program is stateless. No `DynamicBalances`. |
| Fee | Stock `FeeFlatIn` wrapped around `GlideSwap` | No new fee code needed. |
| Fixed-point pow | solady `FixedPointMathLib.powWad` plus a Balancer-style upward error bump | Well-tested, MIT, already a forge dependency pattern. |
| Trade size caps | 30% of balance in, 30% of balance out, same as Balancer | Bounds pow error and keeps the curve away from degenerate regions. |
| Uniswap | v4 hook `GlideHook` with `beforeSwap` + `beforeSwapReturnDelta` + `beforeAddLiquidity` | Full custom accounting so the pool has no liquidity of its own. |
| Chain | Unichain (130) mainnet fork via anvil, pinned block | Aqua, SwapVM, PoolManager, WETH, USDC all verified live there. Base is the fallback. |
| Frontend contract glue | A `GlideLens` view contract encodes orders and taker data on-chain | Avoids reimplementing MakerTraits/TakerTraits byte packing in TypeScript in four days. |
| Tooling | Foundry for contracts, Next.js + wagmi + viem for web | forge 1.5.1 and anvil are installed. Hardhat compile of swap-vm takes ~7 minutes; forge is much faster. |

---

## 1. Background facts that shape the design

These are verified from source, not assumptions.

**SwapVM execution model** (`contracts/libs/VM.sol`, `contracts/SwapVM.sol`)
- A program is bytes: repeated `[uint8 opcode][uint8 argsLength][args]`.
- `Context` has `query` (read-only: orderHash, maker, taker, tokenIn, tokenOut, isExactIn) and `swap` registers (balanceIn, balanceOut, amountIn, amountOut). There is no scratch register, so instructions can only communicate through those four numbers.
- An instruction that wants to run the rest of the program inside itself calls `ctx.runLoop()` (this is how `FeeFlatIn`, `RequireMinRate`, `DynamicBalances` wrap the tail).
- In Aqua mode, `swap()` and `quote()` preload `balanceIn`/`balanceOut` from `AQUA.safeBalances(maker, router, orderHash, tokenIn, tokenOut)` before running the program. Signature checks are skipped. `orderHash = keccak256(abi.encode(order))` and must equal the Aqua `strategyHash = keccak256(strategy)`, so the maker ships with `strategy = abi.encode(order)`.
- Settlement in Aqua mode: output is `AQUA.pull(maker, orderHash, tokenOut, amountOut, to)`. Input is either `AQUA.push` done by the taker in `preTransferInCallback`, or, if the taker sets `useTransferFromAndAquaPush`, the router does `transferFrom(taker → router)` then `AQUA.push` itself. The second path is what a hook or script will use.
- Routers pick their opcode set by overriding `_dispatch`. `AquaSwapVMRouter` is `Simulator, SwapVM, AquaOpcodes`, where `AquaOpcodes._runOpcode` is an if-chain over the enabled instructions.
- `Opcode` enum (`contracts/libs/OpcodeList.sol`) is banked. Curve bank is `0x50–0x6f`; the first free slot is `_52`.

**Aqua** (`aqua/src/Aqua.sol`)
- `ship(app, strategy, tokens[], amounts[])` records virtual balances and returns `keccak256(strategy)`. No tokens move.
- `pull` does `transferFrom(maker, to, amount)`, so the maker's one-time ERC20 approval is to the Aqua contract.
- `dock(app, strategyHash, tokens[])` zeroes and marks docked. Strategies are immutable.
- Unified addresses: Aqua `0x1111113ccf1426a8e30e2bff5e005d929bf6a90a`, official SwapVM router `0x111111338c5091e8440b67b168bae16a668ac0de`.

**Invariant suite** (`test/solidity/invariants/CoreInvariants.t.sol`)
- Abstract contract; you implement `_executeSwap` and call `assertAllInvariantsWithConfig`.
- Checks: symmetry (exactIn then exactOut round trip within `symmetryTolerance` wei), additivity (split vs single swap within `additivityTolerance`), quote/swap consistency (exact match), monotonicity (price never improves with size, bps tolerance), rounding favors maker (1 to 1000 wei trades never beat the 1-token spot rate by more than `roundingToleranceBps`), balance sufficiency (a 1e24 quote either succeeds or reverts).
- Defaults are strict (2 wei symmetry, 0 additivity). A pow-based curve cannot meet 2 wei on 1e18-scale amounts, so we set tolerances explicitly and justify them. See section 7.

**Uniswap v4** (`v4-core/src/test/CustomCurveHook.sol`, `libraries/Hooks.sol`)
- Full custom accounting in `beforeSwap`: `manager.take(input, hook, amountIn)`, then settle the output (`sync`, `transfer`, `settle`), then return `toBeforeSwapDelta(int128(amountIn), -int128(amountOut))` so the specified amount is fully consumed and the concentrated-liquidity path is a no-op.
- Address flags: `BEFORE_SWAP_FLAG = 1<<7`, `BEFORE_SWAP_RETURNS_DELTA_FLAG = 1<<3`, `BEFORE_ADD_LIQUIDITY_FLAG = 1<<11`.
- Unichain PoolManager `0x1f98400000000000000000000000000000000004`, Base PoolManager `0x498581ff718922c3f8e6a244956af099b2652b2b`.

**Unichain fork facts** (checked via `cast` at block 58230608)
- WETH `0x4200000000000000000000000000000000000006`, USDC `0x078D782b760474a361dDA0AF3839290b0EF57AD6` (6 decimals), chain id 130, public RPC `https://mainnet.unichain.org`.

---

## 2. Repository layout

```
ethglobal-online-2026/
├── docs/                       01-overview, 02-product-design, 03-technical-design, FEEDBACK.md (Uniswap)
├── contracts/                  Foundry project
│   ├── foundry.toml            solc 0.8.30, via_ir = true, optimizer_runs 700 (same as swap-vm)
│   ├── remappings.txt
│   ├── package.json            npm deps: @1inch/solidity-utils@6.9.10, @openzeppelin/contracts@5.4.0,
│   │                           github:1inch/aqua#v1.0.0, github:1inch/swap-vm
│   ├── lib/                    forge deps: forge-std, solady, v4-core, v4-periphery
│   ├── src/
│   │   ├── libs/WeightedMath.sol            pure math, no SwapVM imports
│   │   ├── instructions/GlideSwap.sol       the opcode library (build / parse / exec)
│   │   ├── opcodes/GlideOpcodes.sol         AquaOpcodes + GlideSwap dispatch
│   │   ├── routers/GlideSwapVMRouter.sol    Simulator + SwapVM + GlideOpcodes
│   │   ├── periphery/GlideLens.sol          view helpers for the frontend and scripts
│   │   └── hooks/GlideHook.sol              Uniswap v4 hook
│   ├── test/
│   │   ├── WeightedMath.t.sol               unit + fuzz against a reference
│   │   ├── GlideSwap.t.sol                  program behaviour, time warps, fees, direction
│   │   ├── GlideInvariants.t.sol            CoreInvariants harness
│   │   ├── GlideHook.t.sol                  v4 Deployers harness, PoolSwapTest
│   │   └── fork/UnichainFork.t.sol          real Aqua + real PoolManager, WETH/USDC
│   └── script/
│       ├── Deploy.s.sol                     router, lens, hook (mined address), pool init
│       ├── Ship.s.sol                       maker ships a glide position
│       ├── Arb.s.sol                        taker swap direct via router
│       └── SwapViaUniswap.s.sol             taker swap through PoolManager
├── web/                        Next.js app
└── README.md                   points judges to exact files and lines
```

Remappings:

```
@1inch/solidity-utils/=node_modules/@1inch/solidity-utils/
@1inch/aqua/=node_modules/@1inch/aqua/
@1inch/swap-vm/=node_modules/@1inch/swap-vm/
@openzeppelin/contracts/=node_modules/@openzeppelin/contracts/
forge-std/=lib/forge-std/src/
solady/=lib/solady/src/
v4-core/=lib/v4-core/src/
v4-periphery/=lib/v4-periphery/src/
```

`swap-vm` itself depends on the first two through its own `node_modules`; installing all four at the top level with matching versions makes one copy resolve for both. If `github:1inch/swap-vm` fails to install as an npm dependency, fall back to a git submodule at `lib/swap-vm` and remap `@1inch/swap-vm/=lib/swap-vm/`.

---

## 3. The math: `WeightedMath.sol`

Pure library. All values WAD (1e18) unless noted. `w` values are weights in WAD with `wIn + wOut = 1e18`.

### 3.1 Formulas

Exact-in (taker specifies `amountIn`):

```
amountOut = balanceOut * (1 - (balanceIn / (balanceIn + amountIn)) ^ (wIn / wOut))
```

Exact-out (taker specifies `amountOut`):

```
amountIn = balanceIn * ((balanceOut / (balanceOut - amountOut)) ^ (wOut / wIn) - 1)
```

Spot price of tokenOut in tokenIn: `(balanceIn / wIn) / (balanceOut / wOut)`.

### 3.2 Rounding, always in the maker's favour

Follows Balancer V2 `WeightedMath` exactly:

| Step | exact-in | exact-out |
|---|---|---|
| base | `divWadUp(balanceIn, balanceIn + amountIn)` | `divWadUp(balanceOut, balanceOut - amountOut)` |
| exponent | `divWadDown(wIn, wOut)` | `divWadUp(wOut, wIn)` |
| power | `powUp(base, exponent)` | `powUp(base, exponent)` |
| result | `mulWadDown(balanceOut, 1e18 - power)` | `mulWadUp(balanceIn, power - 1e18)` |

Why the exponent rounds differently: in exact-in the base is below 1, so a smaller exponent makes the power larger and the output smaller. In exact-out the base is above 1, so a larger exponent makes the power larger and the input larger.

`powUp(x, y)`:
```
raw = uint256(FixedPointMathLib.powWad(int256(x), int256(y)))
return raw + mulWadUp(raw, MAX_POW_RELATIVE_ERROR) + 1      // MAX_POW_RELATIVE_ERROR = 1e4 (1e-14 relative)
```
solady's `powWad` is documented as an approximation with no direction guarantee, hence the bump. This is the same constant Balancer uses over its own `LogExpMath`.

### 3.3 Guards

- `amountIn <= balanceIn * 30%` and `amountOut <= balanceOut * 30%`, else revert `GlideMaxRatioExceeded`. Enforced in the opcode, not the library.
- `balanceIn > 0 && balanceOut > 0`, else revert `GlideEmptySide`. A weighted curve is undefined with a zero reserve.
- Weights are clamped at build time to `[0.01e18, 0.99e18]`.

### 3.4 Reference test

`WeightedMath.t.sol` fuzzes against a high-precision reference computed with `expWad(lnWad(base) * exp)` at 1e27 scale using solady's 512-bit helpers, asserting `amountOut_ours <= amountOut_ref` and `amountIn_ours >= amountIn_ref` and relative error below 1e-12. Also asserts the classic invariant `balanceIn'^wIn * balanceOut'^wOut >= balanceIn^wIn * balanceOut^wOut` after a swap.

---

## 4. The opcode: `GlideSwap.sol`

Same shape as every stock instruction: a library with `opcode`, `sizeOf`, `build`, `parse`, `exec`.

### 4.1 Encoding

```
[uint40 start][uint32 duration][uint64 wA0][uint64 wA1]     = 25 bytes of args
```

- `start`: unix seconds when the glide begins.
- `duration`: seconds. `0` is rejected at build time.
- `wA0`, `wA1`: weight of token A (the lower address, matching how `StaticBalances` orders its args) at start and at end, WAD. Token B weight is `1e18 - wA`.

Total instruction size: 2 header bytes + 25 = 27 bytes.

### 4.2 `exec`

```solidity
function exec(Context memory ctx, bytes calldata args) internal view {
    (uint40 start, uint32 duration, uint64 wA0, uint64 wA1) = parse(args);

    uint256 wA = _weightNow(start, duration, wA0, wA1);            // linear, clamped to [start, start+duration]
    (uint256 wIn, uint256 wOut) = ctx.query.tokenIn < ctx.query.tokenOut
        ? (wA, 1e18 - wA)
        : (1e18 - wA, wA);

    require(ctx.swap.balanceIn > 0 && ctx.swap.balanceOut > 0, GlideEmptySide());

    if (ctx.query.isExactIn) {
        require(ctx.swap.amountIn <= ctx.swap.balanceIn * MAX_IN_RATIO / 1e18, GlideMaxRatioExceeded());
        ctx.swap.amountOut = WeightedMath.calcOutGivenIn(ctx.swap.balanceIn, wIn, ctx.swap.balanceOut, wOut, ctx.swap.amountIn);
    } else {
        require(ctx.swap.amountOut <= ctx.swap.balanceOut * MAX_OUT_RATIO / 1e18, GlideMaxRatioExceeded());
        ctx.swap.amountIn = WeightedMath.calcInGivenOut(ctx.swap.balanceIn, wIn, ctx.swap.balanceOut, wOut, ctx.swap.amountOut);
    }
}
```

`_weightNow`:
```
if (t <= start) return wA0;
if (t >= start + duration) return wA1;
elapsed = t - start;
return wA0 + (wA1 - wA0) * elapsed / duration      // signed arithmetic, then cast
```

`exec` is `view` (reads `block.timestamp`), writes no storage, and does not call `runLoop`. It is a terminal curve instruction like `XYCSwap`.

### 4.3 Opcode slot

```solidity
Opcode constant opcode = Opcode._52;
```
Curve bank, first free slot, per the comment in `OpcodeList.sol`. We import the enum unchanged.

### 4.4 Why not two opcodes

There is no register to carry a weight from a "GlideWeights" instruction into a "WeightedSwap" instruction; `SwapRegisters` only has the four amounts. Splitting would require abusing `balanceIn`/`balanceOut` as scratch, which breaks the `FeeFlatIn` wrapper and the invariant tests. One opcode is the honest design. This is worth one paragraph in the README because it is a real SwapVM design observation.

---

## 5. Router, program, and Aqua flow

### 5.1 `GlideOpcodes.sol`

```solidity
contract GlideOpcodes is AquaOpcodes {
    function _runOpcode(Context memory ctx, uint256 opcode, bytes calldata args) internal override {
        if (opcode == GlideSwap.opcode.asU8()) GlideSwap.exec(ctx, args);
        else super._runOpcode(ctx, opcode, args);
    }
}
```

Note: `AquaOpcodes` does not include `RequireMinRate`, `DutchAuction*`, `PiecewiseLinearScale*`, or `OraclePriceAdjuster` (those are in `Opcodes`). If we want the optional maker price floor (`RequireMinRate`), we add it to the if-chain the same way. It is a stretch goal.

### 5.2 `GlideSwapVMRouter.sol`

```solidity
contract GlideSwapVMRouter is Simulator, SwapVM, GlideOpcodes {
    constructor(address aqua, address weth, address owner)
        SwapVM(aqua, weth, owner, "GlideSwapVMRouter", "1.0.0") {}
    function _dispatch(Context memory ctx, uint256 opcode, bytes calldata args) internal override {
        _runOpcode(ctx, opcode, args);
    }
}
```

Deployed on the fork with `aqua = 0x1111113c…`, `weth = 0x4200…0006`.

### 5.3 The program

```
FeeFlatIn.build(feeBps)                   // feeBps in 1e7 units, e.g. 0.003e7 = 0.30%
GlideSwap.build(start, duration, wA0, wA1)
Salt.build(random)                        // uniqueness so the same params can be re-shipped later
```

`FeeFlatIn.exec` deducts the fee from `amountIn`, calls `runLoop` which executes `GlideSwap` and `Salt`, then adds the fee back. In Aqua mode the whole `amountIn` including fee is pushed to the maker's Aqua balance, so the fee accrues in the maker's own wallet as tokenIn. No separate fee accounting is needed.

`Deadline` is intentionally not used: after `start + duration` the position simply sits at the end weights and keeps earning fees until docked.

### 5.4 Order

Built with `MakerTraitsLib.build(Args{ maker, tokenA, tokenB (sorted), useAquaInsteadOfSignature: true, receiver: 0, program, all hooks false })`. `order.data = tokenA ‖ tokenB ‖ program`.

### 5.5 Ship

```
1. maker: tokenA.approve(AQUA, max); tokenB.approve(AQUA, max)         (one-time)
2. maker: AQUA.ship(router, abi.encode(order), [tokenA, tokenB], [amtA, amtB])
   -> strategyHash == router.hash(order)
```

`amtA`/`amtB` are the amounts the maker exposes. They can be less than wallet balances. Both must be greater than zero.

**Initial weight rule.** The pool's spot price is `(amtA / wA) / (amtB / wB)`. If that is not the market price, arbitrage moves the wallet immediately and the maker eats the gap. So `wA0` is *derived*, not chosen:

```
wA0 = valueA / (valueA + valueB),  valueA = amtA * priceA, valueB = amtB * priceB
```

The frontend computes this from the exposed amounts and a reference price, and shows the implied pool price next to the market price. The maker chooses only `wA1` (end weight), `start`, `duration`, and the fee.

### 5.6 Taker swap, direct

```
takerTraits = TakerTraitsLib.build(Args{
    taker, isExactIn: true, isAToB: (tokenIn == tokenA),
    useTransferFromAndAquaPush: true,            // router pulls from taker and pushes to Aqua
    threshold: bytes32(minOut), to: recipient, deadline, everything else empty
})
tokenIn.approve(router, amountIn)
router.swap(order, amountIn, takerTraits)
```

Result: `AQUA.pull(maker → recipient, tokenOut)` and `transferFrom(taker → router) + AQUA.push(router → maker, tokenIn)`. The maker's wallet changes by exactly `(+amountIn, -amountOut)`.

### 5.7 Dock

```
maker: AQUA.dock(router, strategyHash, [tokenA, tokenB])
```

Docking must list all tokens of the strategy or Aqua reverts with `DockingShouldCloseAllTokens`.

---

## 6. `GlideLens.sol`

Stateless view contract so the web app and scripts never hand-pack traits.

```solidity
struct GlideParams { address tokenA; address tokenB; uint24 feeBps; uint40 start; uint32 duration; uint64 wA0; uint64 wA1; uint64 salt; }

function buildOrder(address maker, GlideParams p) external pure returns (ISwapVM.Order memory);
function encodeShipStrategy(address maker, GlideParams p) external pure returns (bytes memory);   // abi.encode(order)
function orderHash(address maker, GlideParams p) external view returns (bytes32);
function takerData(address taker, bool isExactIn, bool aToB, uint256 threshold, address to, uint40 deadline) external pure returns (bytes memory);
function quote(ISwapVM.Order order, bool aToB, uint256 amountIn) external view returns (uint256 amountOut);
function weightNow(GlideParams p) external view returns (uint256 wA);
function state(address maker, ISwapVM.Order order) external view returns (uint256 balA, uint256 balB, uint256 wA, uint256 spotPriceAinB);
function deriveStartWeight(uint256 amtA, uint256 amtB, uint256 priceAinB) external pure returns (uint64 wA0);
```

The frontend stores `(maker, GlideParams)` in localStorage after shipping and reconstructs everything else through the lens. Trade history comes from `Swapped` events on the router filtered by `orderHash`.

---

## 7. Tests

### 7.1 `GlideSwap.t.sol` (behaviour)

Uses `AquaSwapVMTest` from swap-vm as the base (deploys a fresh `Aqua`, two `TokenMock`s, `MockTaker`). Override `_deployRouter` to return `GlideSwapVMRouter`.

- Ship with 50/50 weights and equal balances: quote equals `XYCSwap` quote within 1e-12 relative. Sanity anchor.
- Weight 80/20 with balances 80/20: spot price is 1:1. Spot price formula check.
- `vm.warp` through the window: weight moves linearly, clamped before and after.
- Both directions (A→B, B→A) at an asymmetric weight.
- Exact-in and exact-out.
- Fee: maker Aqua balance of tokenIn grows by `amountIn` including fee; taker paid fee.
- Reverts: zero side, over 30% in, over 30% out, duration 0 at build, weights out of range at build.
- Full glide simulation: ship at market-consistent weights, warp in 10 steps, at each step have a "rational arb" swap until spot equals an external price, assert the wallet value share tracks `wA(t)` within a tolerance, and total fees collected > 0. This is the demo in test form.

### 7.2 `GlideInvariants.t.sol`

Inherits `CoreInvariants`, implements `_executeSwap` (mint tokenIn to taker, call `router.swap`). Runs `assertAllInvariantsWithConfig` for three programs (50/50, 80/20, 20/80) at three timestamps (before, mid, after window) and with and without `FeeFlatIn`.

Tolerances and their justification, to be written into the test as comments and into the README:

| Invariant | Setting | Reason |
|---|---|---|
| symmetry | `amount * 1e-12` wei, minimum 2 | Two `powUp` bumps of 1e-14 relative each way, plus divWad rounding. Round trip always costs the taker, never the maker. |
| additivity | `amount * 1e-12` wei | Same source. Constant-mean with reinvested reserves is additive in exact arithmetic. |
| monotonicity | 0 bps | Exact property of the curve. |
| rounding favors maker | 100 bps default | 1-wei trades round to 0 output. |
| quote/swap | exact | Program is a pure function of `block.timestamp` and Aqua balances. |
| balance sufficiency | default | 1e24 quote reverts on the 30% cap. Caught by the `try`. |

Additionally: a fuzz that a sequence of random swaps in random directions never makes `balanceA^wA * balanceB^wB` decrease (the maker's invariant never shrinks in a fixed-weight window).

### 7.3 `GlideHook.t.sol`

Uses `v4-core/test/utils/Deployers.sol` for `manager`, `swapRouter` (`PoolSwapTest`), currencies. Deploy `GlideSwapVMRouter` and a fresh `Aqua` locally. Mine the hook address with `v4-periphery/src/utils/HookMiner.sol` and deploy with CREATE2 to that salt. Initialize a pool `(currency0, currency1, fee 0, tickSpacing 60, hooks)` at sqrtPrice 1:1. Ship a Glide position. Swap through `swapRouter` exact-in and assert the maker's Aqua balances changed by `(+in, -out)`, the swapper received `out`, and `manager` holds zero of either token afterwards. Assert exact-out reverts with `GlideHookExactInOnly`. Assert `modifyLiquidity` reverts.

### 7.4 `fork/UnichainFork.t.sol`

`vm.createSelectFork(UNICHAIN_RPC, PINNED_BLOCK)`. Uses the real Aqua and real PoolManager. Seeds WETH via `deal` and USDC via `deal` (forge-std's `deal` handles FiatToken's balance slot via `stdstore`; if it fails, write slot 9 directly). Ships WETH/USDC, swaps directly, swaps through Uniswap. This is the test that proves the demo path before we record it.

---

## 8. `GlideHook.sol`

### 8.1 Permissions and address

```
getHookPermissions: beforeSwap = true, beforeSwapReturnDelta = true, beforeAddLiquidity = true, all else false
flags = BEFORE_SWAP_FLAG | BEFORE_SWAP_RETURNS_DELTA_FLAG | BEFORE_ADD_LIQUIDITY_FLAG   // 1<<7 | 1<<3 | 1<<11
```
Address mined with `HookMiner.find(deployer, flags, creationCode, constructorArgs)`. Deployed via CREATE2 (in tests: `new GlideHook{salt: salt}(...)`; in scripts: the same, since forge scripts deploy from the script contract's CREATE2 deployer, or use the canonical `0x4e59b44847b379578588920cA78FbF26c0B4956C` factory).

### 8.2 State

```solidity
struct Route { address maker; bytes order; bool aToB0; }     // order = abi.encode(ISwapVM.Order); aToB0 = (currency0 == order.tokenA)
mapping(PoolId => Route) public routes;
GlideSwapVMRouter public immutable ROUTER;
IAqua public immutable AQUA;

function registerRoute(PoolKey calldata key, ISwapVM.Order calldata order) external;   // msg.sender must equal order.maker; key.hooks must be this
```

One route per pool. The pool key's currencies must equal the order's token pair (checked). A maker who docks should also call `clearRoute`, but an un-cleared route simply reverts on swap because `safeBalances` reverts for a docked strategy.

### 8.3 `_beforeSwap`

```solidity
function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
    internal override returns (bytes4, BeforeSwapDelta, uint24)
{
    require(params.amountSpecified < 0, GlideHookExactInOnly());
    Route storage r = routes[key.toId()];
    require(r.maker != address(0), GlideHookNoRoute());

    (Currency cIn, Currency cOut) = params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
    uint256 amountIn = uint256(-params.amountSpecified);
    uint256 minOut = hookData.length == 32 ? abi.decode(hookData, (uint256)) : 0;

    // 1. pull the swapper's input out of the PoolManager into this contract
    poolManager.take(cIn, address(this), amountIn);

    // 2. fill against the Glide position; this contract is the SwapVM taker
    IERC20(Currency.unwrap(cIn)).forceApprove(address(ROUTER), amountIn);
    ISwapVM.Order memory order = abi.decode(r.order, (ISwapVM.Order));
    bool aToB = params.zeroForOne ? r.aToB0 : !r.aToB0;
    bytes memory takerData = TakerTraitsLib.build(Args{ taker: address(this), isExactIn: true, isAToB: aToB,
        useTransferFromAndAquaPush: true, threshold: bytes32(minOut), to: address(this), ... });
    (, uint256 amountOut,) = ROUTER.swap(order, amountIn, takerData);

    // 3. hand the output to the PoolManager so it can pay the swapper
    poolManager.sync(cOut);
    IERC20(Currency.unwrap(cOut)).safeTransfer(address(poolManager), amountOut);
    poolManager.settle();

    // 4. tell the PoolManager the whole specified amount is consumed and how much output exists
    return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(int128(int256(amountIn)), -int128(int256(amountOut))), 0);
}
```

`_beforeAddLiquidity` reverts with `GlideHookNoLiquidity`. The pool is initialised with `fee = 0` so the PoolManager charges nothing on top; the maker's fee is inside the SwapVM program.

Delta sign convention is copied from `CustomCurveHook`, which returns `toBeforeSwapDelta(-amountSpecified, amountSpecified)` for a 1:1 curve. Ours generalises the unspecified leg to the actual output.

### 8.4 Limits, stated in FEEDBACK.md and README

- Exact-in only. Exact-out is possible (quote first, then take the computed input) but not in scope.
- Single position per pool. A multi-maker aggregation is the obvious next step.
- No native ETH; the pool must use WETH because Aqua is ERC20-only.

---

## 9. Scripts and the fork runbook

```bash
# terminal 1: pinned fork, chain id stays 130
anvil --fork-url https://mainnet.unichain.org --fork-block-number 58230608 --block-time 2

# terminal 2
export RPC=http://127.0.0.1:8545
export MAKER=<anvil account 0>   TAKER=<anvil account 1>
# seed: WETH by deposit, USDC by storage write (FiatTokenV2 balances mapping is slot 9)
cast send 0x4200000000000000000000000000000000000006 "deposit()" --value 20ether --private-key $MAKER_PK --rpc-url $RPC
cast rpc anvil_setStorageAt 0x078D782b760474a361dDA0AF3839290b0EF57AD6 $(cast index address $TAKER 9) $(cast to-uint256 100000000000) --rpc-url $RPC

forge script script/Deploy.s.sol --rpc-url $RPC --broadcast           # router, lens, hook, pool init; writes deployments/130.json
forge script script/Ship.s.sol   --rpc-url $RPC --broadcast           # maker: approve Aqua, ship position, registerRoute
cast rpc evm_increaseTime 3600 --rpc-url $RPC && cast rpc evm_mine --rpc-url $RPC
forge script script/Arb.s.sol    --rpc-url $RPC --broadcast           # taker: direct router swap
forge script script/SwapViaUniswap.s.sol --rpc-url $RPC --broadcast  # taker: PoolSwapTest -> PoolManager -> hook -> router -> Aqua
```

`Deploy.s.sol` also deploys a `PoolSwapTest` from v4-core so the Uniswap-path demo does not need Permit2 and the Universal Router.

If Unichain RPC is unreliable during recording, the same scripts run against Base with `deployments/8453.json` (PoolManager `0x4985…`, USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`).

---

## 10. Frontend (`web/`)

Stack: Next.js 15 (app router), wagmi v2 + viem, injected connector only, Tailwind, recharts. Custom wagmi chain definition for the fork: id 130, RPC `http://127.0.0.1:8545`.

ABIs come from `contracts/out/*.json` copied at build time by a small script. Deployed addresses are read from `contracts/deployments/130.json`.

Pages:

1. **/create**
   - Inputs: pair (fixed list: WETH, USDC), exposed amounts A and B, reference price (prefilled from a constant, editable), end weight slider, start (now), duration, fee.
   - Derived: `wA0` via `lens.deriveStartWeight`, implied pool price vs reference price with a warning if off by more than 1%.
   - Chart: `wA(t)` line from `wA0` to `wA1`.
   - Buttons: Approve A, Approve B (to Aqua), Ship (calls `Aqua.ship(router, lens.encodeShipStrategy(...), tokens, amounts)`), then Register Uniswap route (calls `hook.registerRoute`).
   - Persists `GlideParams` and `orderHash` to localStorage.

2. **/position**
   - Reads `lens.state` every block: balances, `wA(t)`, spot price, and actual value share (using reference price).
   - Chart: target weight line with actual value share as points over time (points appended from `Swapped` events with block timestamps).
   - Fees earned: sum over `Swapped` events of `amountIn * feeBps / 1e7` by token.
   - Trade table: direction, in, out, tx hash link (to nothing on a fork; shown as text).
   - Dock button.

3. **/demo** (taker tools, not in the product story)
   - "Arb to market": quotes small steps and executes direct router swaps until spot is within 10 bps of the reference price. Shows each tx.
   - "Swap via Uniswap": one exact-in swap through `PoolSwapTest`.
   - "Advance time": calls `evm_increaseTime` + `evm_mine` over JSON-RPC (fork only).

Wallet handling: the maker is anvil account 0 and the taker is account 1, both imported into the browser wallet. No signing of orders is needed anywhere because Aqua mode replaces signatures.

---

## 11. README and submission checklist

- README sections: what it is, architecture diagram, "for 1inch judges" with links to `GlideSwap.sol` lines, `WeightedMath.sol`, `GlideSwapVMRouter.sol`, invariant test; "for Uniswap judges" with links to `GlideHook.sol` `_beforeSwap` and the hook test; runbook; limits.
- `docs/FEEDBACK.md` for Uniswap: notes on custom accounting docs, HookMiner ergonomics, PoolSwapTest vs Universal Router for local testing, anything that bit us. Submit the Uniswap feedback form with its link.
- Video 2 to 4 minutes, recorded from the scripted runbook, human voice.
- Commit history: keep changes small and descriptive.
- ETHGlobal submission selects exactly two partner prizes: 1inch "Build an Aqua App", Uniswap Foundation "Best Uniswap Stack Contribution".

---

## 12. Implementation milestones

| Milestone | Done means |
|---|---|
| Foundation | Foundry compiles with swap-vm, aqua, solady and v4 dependencies. WeightedMath fuzz tests pass. GlideSwap and its router compile. |
| Program tests | GlideSwap behaviour tests and the glide simulation pass. CoreInvariants pass with documented tolerances. GlideLens builds orders and reads position state. |
| Integration | GlideHook tests pass. The Unichain fork test ships and swaps through Aqua and PoolManager. Scripts and the runbook work end to end. |
| App and submission | Create, position and demo pages work against the fork. README, FEEDBACK.md, video and submission materials are complete. |

If scope must shrink, cut the demo page first (use scripts), then exact-in minOut
via hookData, then the value-share chart (show numbers only). Keep the hook only
if its tests pass before submission.

---

## 13. What changed during implementation

Recorded after the build so the doc matches the code.

- **`BaseHook` no longer exists in v4-periphery main.** `GlideHook` implements `IHooks` directly with reverting stubs
  and calls `Hooks.validateHookPermissions` in its constructor. `HookMiner` lives in `v4-periphery/test/shared/`.
- **PoolManager is built in its own Foundry profile.** It pins `solc 0.8.26` and fails under `via_ir`, while SwapVM
  pins `0.8.30`. `FOUNDRY_PROFILE=v4 forge build` writes `out-v4/`, and `test/utils/V4Artifacts.sol` deploys the
  PoolManager from that artifact. `Deployers.sol` could not be used for the same reason; the hook test wires
  `PoolSwapTest` and `PoolModifyLiquidityTest` by hand.
- **Flash accounting float.** `beforeSwap` takes the swapper's input from the PoolManager before the swapper settles,
  so the manager must already hold that much of the token. True on any live deployment; the unit test pre-funds the
  fresh manager to simulate other pools. Documented in the hook and in FEEDBACK.md.
- **Invariant tolerances.** Symmetry and additivity run at 1e9 wei on 1e18-scale amounts (about 1e-9 tokens), and each
  fixture's trade sizes are chosen so `3 × amount` stays under the 30% caps on both sides. See the header of
  `test/GlideInvariants.t.sol`.
- **Big numbers in JSON.** `Ship.s.sol` writes weights, amounts and prices as decimal strings so the web app can parse
  them without precision loss.
- **Demo accounts instead of an injected wallet.** The web app signs with anvil's maker and taker keys via viem so the
  demo never depends on a browser extension talking to a fork. `GlideLens` does all order and taker-traits encoding.
- **Deploy uses the canonical CREATE2 deployer** (`0x4e59…956C`, present on Unichain) so the mined hook address is
  reproducible from a script.
- **Port 8546.** The runbook expects anvil on `--port 8546` when 8545 is already taken.

- **Piecewise schedules.** `GlideSwapPiecewise` at `Opcode._55` encodes
  `[start, w0, (duration_i, w_{i+1})…]`, up to 20 segments in the 255-byte args limit, and reuses
  `GlideSwap.applyWeight` for the curve. `GlideParams` gained `weights[]`/`durations[]`; empty means the linear opcode.
  The lens validates that the schedule's endpoints and total match `wA0`, `wA1`, `duration`. The app generates
  schedules from six shape presets with 12 points (2 for the hold variants).

## 14. Open risks (as written before implementation)

- **swap-vm as npm dependency.** `package.json` says `@1inch/swap-vm` 0.0.6 but it may not be on the registry. Fallback is the git submodule. Decide in the first hour.
- **via_ir compile time.** SwapVM needs it. Expect 1 to 3 minutes per full forge build; use `forge test --match-path` aggressively.
- **v4-periphery `BaseHook` signature drift.** Pin `v4-periphery` to the commit whose `BaseHook` uses `SwapParams` from `v4-core/types/PoolOperation.sol`; adjust the override signature to whatever the pinned version declares.
- **`deal` on USDC.** forge-std `deal` uses `stdstore` to find the balance slot and works on FiatToken in practice; if it does not, write slot 9 directly.
- **Initial-weight mismatch in the demo.** If the reference price in the UI does not match what the arb script uses, the first arb looks like a loss. Both read the same constant from `deployments/130.json`.
