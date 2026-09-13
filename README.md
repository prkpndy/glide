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

## Try the demo (judges)

Open the **hosted frontend linked in our ETHGlobal submission** after starting Anvil and running setup below.
The frontend runs on Vercel and connects to an Anvil fork on **your own computer**. Setup funds the demo maker/taker
accounts and deploys Glide locally; all trades use fork tokens. You do not need to install the frontend or connect MetaMask.

You need **Git**, **Foundry (`forge`, `cast`, and `anvil`, version 1.5+)**, an internet connection for the Unichain fork,
and a desktop browser. Use the same repository version as the submission.

### 1. Start Anvil — terminal 1

```bash
anvil --host 127.0.0.1 --port 8546 \
  --fork-url https://mainnet.unichain.org \
  --fork-block-number 58230608 \
  --chain-id 130
```

Leave this terminal running while you use the demo. Start with a fresh fork and keep the default Anvil accounts.
Anvil accepts browser requests by default; it listens only on your computer at `127.0.0.1:8546`.

### 2. Deploy and fund the demo — terminal 2

```bash
git clone --recursive https://github.com/prkpndy/glide.git
cd glide/contracts
forge build
RPC=http://127.0.0.1:8546 ./scripts/setup.sh
```

If you already cloned the repository, run `git submodule update --init --recursive` from its root before building.
Wait for setup to report success. It gives the maker **5,000 USDC + 20 WETH**, funds the taker, and deploys the Glide
router, lens, hook and Uniswap pool. Run setup once per fresh fork. Its fixed deployment salt makes the contract
addresses match the hosted frontend when you use the same contract build.

### 3. Connect the hosted frontend

Open the hosted frontend in a browser on the same computer and click **Connect local fork** in the header.
Allow **local network access** if your browser asks. A block number in the header means the connection succeeded.
Keep Anvil running; you can now create positions and trade from the hosted page.

Your browser sends requests directly to your local Anvil node. Each judge gets an independent fork; other visitors
cannot see or change your demo through the hosted site.

### What to try

1. On **Create**, keep the **maker** account selected. Keep the default amounts, choose **Linear** or **S-curve**, and click **Approve & ship**.
2. On **Position**, inspect the target share, actual share and exposed balances.
3. Open **Demo tools**, switch to **taker** in the header, and click **+6h** to advance the fork's clock.
4. Click **Arb until within 50 bps**. The trades move the maker's allocation towards the target and earn fees.
5. Keep the Uniswap route selected and click **Swap** to trade through the v4 hook. Return to **Position** to see the trades and fees.
6. Switch back to **maker** and click **Dock position** to stop the strategy.

### If the connection fails

- **Cannot reach Anvil:** check that terminal 1 is still running on port `8546`, then click **Connect local fork** again.
- **Browser blocks localhost:** allow local network access for the hosted site and retry. See [Chrome's permission guide](https://developer.chrome.com/blog/local-network-access).
  If you started Anvil with `--allow-origin`, that value must match the hosted page's origin exactly.
- **Contracts do not match:** use the submission's repository version, restart a fresh fork with the command above,
  and run `setup.sh` again with its default accounts and deployment salt.
- **Old position after restarting Anvil:** click **Forget** on Position, then create a new one. Restarting a fresh fork
  resets its trades and positions; the browser may still remember the previous position.

## How it works

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

The new pieces are two SwapVM instructions, **`GlideSwap`** (straight-line schedule) and **`GlideSwapPiecewise`** (any
piecewise-linear schedule), plus the math library under them, in a redeployed router.
Everything settles through the official Aqua registry at `0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a`.

| What | Where |
|---|---|
| The opcode: time-interpolated weight, then the weighted curve. Terminal instruction, `view`, stateless in Aqua mode | [`contracts/src/instructions/GlideSwap.sol`](contracts/src/instructions/GlideSwap.sol) (`weightAt` L59, `exec` L69, `applyWeight` L75) |
| Second opcode at `Opcode._55`: the same curve on a piecewise-linear weight schedule (ease-in, S-curve, hold-then-move, up to 20 segments) | [`contracts/src/instructions/GlideSwapPiecewise.sol`](contracts/src/instructions/GlideSwapPiecewise.sol) (`weightAt` L77, `exec` L95) |
| Weighted constant-mean math with maker-favouring rounding (Balancer V2 structure, solady `powWad` with an upward error bump, 30% trade caps) | [`contracts/src/libs/WeightedMath.sol`](contracts/src/libs/WeightedMath.sol) (`calcOutGivenIn` L30, `calcInGivenOut` L52, `powUp` L83) |
| Both opcodes wired into the stock Aqua instruction set (`_52`, `_55`, the free slots of the curve bank) | [`contracts/src/opcodes/GlideOpcodes.sol`](contracts/src/opcodes/GlideOpcodes.sol) L15 |
| Router = `Simulator` + `SwapVM` + Aqua opcodes + `GlideSwap` | [`contracts/src/routers/GlideSwapVMRouter.sol`](contracts/src/routers/GlideSwapVMRouter.sol) |
| 1inch's `CoreInvariants` suite at fixed, extreme and gliding weights, with and without fees, at three points in time. Tolerances and why in the header | [`contracts/test/GlideInvariants.t.sol`](contracts/test/GlideInvariants.t.sol) |
| The product as a test: an arbitrageur keeps the pool at the market price and the maker's value share tracks the glide path | [`contracts/test/GlideSwap.t.sol`](contracts/test/GlideSwap.t.sol) `test_GlideSimulation_ValueShareTracksWeight` L212 |
| Math fuzzed against an unrounded reference: maker never overpays, invariant never decreases, concavity, round trip | [`contracts/test/WeightedMath.t.sol`](contracts/test/WeightedMath.t.sol) |
| Piecewise schedule: exact weights at every breakpoint, a one-segment schedule quotes identically to the linear opcode, prices freeze during a hold, invariants inside a segment and inside a hold | [`contracts/test/GlidePiecewise.t.sol`](contracts/test/GlidePiecewise.t.sol) |
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

## Local development and tests (optional)

The hosted demo above does not require Node.js. To run the frontend locally, install Node 20+ and start/setup Anvil
as described above. Then, from the repository root:

```bash
cd web
npm ci
npm run dev                         # http://localhost:3000; connects to Anvil automatically
# In another terminal, from web/:
node scripts/e2e.mjs                 # create → time travel → arb → Uniswap swap
```

To run the contract tests, from the repository root:

```bash
cd contracts
forge build
FOUNDRY_PROFILE=v4 forge build       # separate PoolManager artifact required by hook tests
forge test --no-match-path 'test/fork/*'
forge test --match-path test/fork/UnichainFork.t.sol
```

The fork tests need RPC access; `UNICHAIN_RPC_URL` overrides the public endpoint. For a terminal-only demo on a fresh
Anvil fork, run `RPC=http://127.0.0.1:8546 ./scripts/demo.sh` from `contracts/` instead of `setup.sh`.

<details>
<summary>Publishing the frontend (maintainers)</summary>

After building contracts and successfully running `setup.sh`, from `web/`:

```bash
npm ci
npm run sync       # update the ABI/deployment snapshot under generated/
npm run build      # build from that snapshot without running Forge
```

Review `web/generated/` with the code. Import the repository into Vercel with **Root Directory = `web`**,
**Framework = Next.js**, **Install = `npm ci`**, and **Build = `npm run build`**. `web/vercel.json` supplies the build
settings. The default RPC (`http://127.0.0.1:8546`) and chain ID (`130`) match the judges' setup; no Vercel environment
variables are required. Remove any old hosted-chain overrides for `NEXT_PUBLIC_RPC_URL` and `NEXT_PUBLIC_CHAIN_ID`.

Vercel serves the frontend snapshot and never connects to Anvil itself. After changing contracts, rebuild, run setup
and sync, then redeploy the frontend. Judges must use that same repository version on a fresh fork. Add the deployed
frontend URL to the submission's Demo link.

</details>

## Repository map

```
contracts/
  src/libs/WeightedMath.sol          curve math
  src/instructions/GlideSwap.sol     the opcode (linear schedule)
  src/instructions/GlideSwapPiecewise.sol  the opcode (piecewise schedule)
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
