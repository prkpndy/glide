# Glide

**Set a target. Let the market rebalance you. Get paid for it.**

Glide is self-custodial glide-path liquidity on [1inch Aqua](https://github.com/1inch/aqua), reachable through a
[Uniswap v4](https://github.com/Uniswap/v4-core) pool. A maker keeps tokens in their own wallet and publishes a
*glide path*: a start value split, an end value split, and a time window. The position prices itself like a weighted
AMM whose weights slide along that path, so arbitrageurs gradually convert the wallet along the path and pay the maker
a fee on every trade, instead of the maker paying slippage to a bot or a DEX. It is a Liquidity Bootstrapping Pool for
a single wallet, with no pool contract holding the money.

Built for ETHOnline 2026. Submitted to **1inch: Build an Aqua App** and **Uniswap Foundation: Best Uniswap Stack
Contribution**.

```
                       maker's wallet (tokens never leave until a trade)
                                  ▲ pull / push via Aqua
                                  │
   taker ──► GlideSwapVMRouter ───┤  program: FeeFlatIn → GlideSwap(start, duration, wA0, wA1) → Salt
                 ▲                │
   Uniswap v4 ───┘                │
   PoolManager ──► GlideHook (beforeSwap custom accounting, pool holds no liquidity)
```

## For 1inch judges

The new piece is one SwapVM instruction, **`GlideSwap`**, plus the math library under it, in a redeployed router.
Everything settles through the official Aqua registry at `0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a`.

| What | Where |
|---|---|
| The opcode: time-interpolated weight, then the weighted curve. Terminal instruction, `view`, stateless in Aqua mode | [`contracts/src/instructions/GlideSwap.sol`](contracts/src/instructions/GlideSwap.sol) (`weightAt` L59, `exec` L69) |
| Weighted constant-mean math with maker-favouring rounding (Balancer V2 structure, solady `powWad` with an upward error bump, 30% trade caps) | [`contracts/src/libs/WeightedMath.sol`](contracts/src/libs/WeightedMath.sol) (`calcOutGivenIn` L30, `calcInGivenOut` L52, `powUp` L83) |
| Opcode wired into the stock Aqua instruction set at slot `Opcode._52` (first free slot of the curve bank) | [`contracts/src/opcodes/GlideOpcodes.sol`](contracts/src/opcodes/GlideOpcodes.sol) L14 |
| Router = `Simulator` + `SwapVM` + Aqua opcodes + `GlideSwap` | [`contracts/src/routers/GlideSwapVMRouter.sol`](contracts/src/routers/GlideSwapVMRouter.sol) |
| 1inch's `CoreInvariants` suite at fixed, extreme and gliding weights, with and without fees, at three points in time. Tolerances and why in the header | [`contracts/test/GlideInvariants.t.sol`](contracts/test/GlideInvariants.t.sol) |
| The product as a test: an arbitrageur keeps the pool at the market price and the maker's value share tracks the glide path | [`contracts/test/GlideSwap.t.sol`](contracts/test/GlideSwap.t.sol) `test_GlideSimulation_ValueShareTracksWeight` L212 |
| Math fuzzed against an unrounded reference: maker never overpays, invariant never decreases, concavity, round trip | [`contracts/test/WeightedMath.t.sol`](contracts/test/WeightedMath.t.sol) |
| Real Aqua on a Unichain mainnet fork, USDC/WETH, ship → swap → dock | [`contracts/test/fork/UnichainFork.t.sol`](contracts/test/fork/UnichainFork.t.sol) |

Design notes worth a minute:

- **Why one opcode and not two.** SwapVM instructions communicate only through the four swap registers, so a separate
  "weight schedule" instruction cannot hand a weight to a curve instruction. Schedule and curve are one opcode.
- **Why the start weight is derived.** A weighted pool's spot price is fixed by reserves and weights. If the start
  weight does not match the value split at market price, arbitrage takes the gap in the first trade. So the maker
  chooses only the end weight, the window and the fee; the start weight comes from the exposed amounts and a reference
  price (`GlideLens.deriveStartWeight`).
- **Aqua mode means no state.** Balances come from `Aqua.safeBalances` on every quote and swap, so the program is a pure
  function of `block.timestamp` and the maker's exposed balances. Fees accrue as `tokenIn` in the maker's own wallet.

## For Uniswap judges

**`GlideHook`** is a v4 hook with `beforeSwap` + `beforeSwapReturnDelta` + `beforeAddLiquidity`. The pool never holds
liquidity: the hook takes the swapper's input from the PoolManager, fills it against the Glide order through the
router, settles the output back, and returns a delta that consumes the whole specified amount.

| What | Where |
|---|---|
| `beforeSwap`: take → fill via SwapVM/Aqua → sync/transfer/settle → `toBeforeSwapDelta(+amountIn, -amountOut)` | [`contracts/src/hooks/GlideHook.sol`](contracts/src/hooks/GlideHook.sol) L122-L156 (take L136, fill L142, settle L145-147, delta L154) |
| One route per pool, registered by the order's maker, token pair checked against the pool key | `registerRoute` L97 |
| Liquidity is refused so the pool can never hold tokens | `beforeAddLiquidity` L187 |
| Hook permissions and address flags | `getHookPermissions` L70; mined with `HookMiner` in tests and in [`contracts/script/Deploy.s.sol`](contracts/script/Deploy.s.sol) |
| Unit test with a fresh PoolManager: fills from the maker's wallet, nothing left in manager/hook/router, exact-out and liquidity revert, min-out enforced, gliding price visible through Uniswap | [`contracts/test/GlideHook.t.sol`](contracts/test/GlideHook.t.sol) `test_SwapThroughUniswap_FillsFromMakerWallet` L136 |
| The real Unichain PoolManager on a fork: USDC→WETH and WETH→USDC through `PoolSwapTest` | [`contracts/test/fork/UnichainFork.t.sol`](contracts/test/fork/UnichainFork.t.sol) `test_SwapViaUniswap_UsdcForEth` L141 |
| Developer feedback | [`docs/FEEDBACK.md`](docs/FEEDBACK.md) |

Limits, stated plainly: exact-in only; ERC20 currencies only (Aqua is ERC20-only); the `take` in `beforeSwap` relies on
the PoolManager's aggregate float, which holds on any live deployment and not on an empty test manager (the unit test
pre-funds it).

## Run it

Requirements: Foundry (forge 1.5+), Node 20+, network access for the Unichain fork.

```bash
# contracts
cd contracts
forge build                          # SwapVM + Glide, solc 0.8.30, via_ir
FOUNDRY_PROFILE=v4 forge build       # Uniswap PoolManager (solc 0.8.26, no via_ir) -> out-v4/
forge test --no-match-path 'test/fork/*'          # 41 unit, fuzz, invariant and hook tests
forge test --match-path test/fork/UnichainFork.t.sol   # needs RPC; UNICHAIN_RPC_URL overrides the public one

# end-to-end on a local fork (terminal 1)
anvil --port 8546 --fork-url https://mainnet.unichain.org --fork-block-number 58230608 --chain-id 130
# terminal 2: deploy, ship a USDC/WETH glide, swap directly, jump 12h, swap through Uniswap both ways
RPC=http://127.0.0.1:8546 ./scripts/demo.sh

# web app (reads contracts/deployments/*.json)
cd ../web && npm install && npm run dev      # http://localhost:3000, RPC defaults to 127.0.0.1:8546
node scripts/e2e.mjs                         # drives create → time travel → arb → Uniswap swap in headless Chromium
```

The app has three pages: **Create** (derive start weight, preview the path, approve and ship, register the Uniswap
route), **Position** (target vs actual value share from router `Swapped` events, fees earned, trades, dock), and
**Demo tools** (fork time travel, an arbitrage loop that pushes the pool back to the reference price, swaps directly
or through the Uniswap v4 pool). It signs with anvil's maker and taker accounts so the demo does not depend on a
browser wallet.

## Repository map

```
contracts/
  src/libs/WeightedMath.sol          curve math
  src/instructions/GlideSwap.sol     the opcode
  src/opcodes/GlideOpcodes.sol       Aqua opcode set + GlideSwap
  src/routers/GlideSwapVMRouter.sol  the redeployed router
  src/periphery/GlideLens.sol        order / taker-traits / state helpers for clients
  src/hooks/GlideHook.sol            Uniswap v4 hook
  test/                              unit, fuzz, invariants, hook, fork
  script/                            Deploy, Ship, Swap (forge scripts)
  scripts/demo.sh                    anvil fork runbook
web/                                 Next.js + viem app
docs/                                overview, product design, technical design, Uniswap feedback
```

Dependencies are git submodules under `contracts/lib`: `1inch/swap-vm` (main, `f09a41e`), `1inch/aqua` v1.0.0,
`1inch/solidity-utils` 6.9.10, OpenZeppelin 5.4.0, solady 0.1.26, `Uniswap/v4-periphery` (with its nested v4-core).
