# Glide

Self-custodial glide-path liquidity on 1inch Aqua, with swaps routed through Uniswap v4.
A maker publishes a target value split and time window while keeping tokens in their wallet.

## Design

- [Overview](docs/01-overview.md)
- [Product design](docs/02-product-design.md)
- [Technical design](docs/03-technical-design.md)

The design documents describe the intended product and implementation plan.

## Contracts

Dependencies are pinned as Git submodules. From the repository root, run
`git submodule update --init --recursive`, then `cd contracts`.

## Weighted math

`src/libs/WeightedMath.sol` implements weighted constant-mean quotes, maker-favouring
rounding and trade caps. `test/WeightedMath.t.sol` covers the curve and rounding properties.

```bash
forge build
forge test --match-path test/WeightedMath.t.sol
```

## Glide instruction and router

`GlideSwap` interpolates token-A's weight across the time window. `GlideOpcodes`
adds the instruction to the Aqua opcode set and `GlideSwapVMRouter` executes it.
The behaviour tests include a glide simulation and swaps settled through Aqua.

```bash
forge test --match-path test/GlideSwap.t.sol
```

## Client helpers and invariants

`src/periphery/GlideLens.sol` builds orders and ship bytes, encodes taker traits,
and reads quotes and position state. `test/GlideInvariants.t.sol` applies SwapVM's
CoreInvariants harness to fixed, extreme and gliding weights, with and without fees.

```bash
forge test --match-path test/GlideInvariants.t.sol
```

## Uniswap v4 hook

`GlideHook` fills exact-input ERC20 swaps through Aqua using v4 custom accounting.
It rejects liquidity additions and exact-output swaps. The unit test deploys a
fresh PoolManager and checks settlement, permissions and route validation.

PoolManager uses solc 0.8.26 without via_ir, so build its separate profile before
running hook tests; the test helper loads `out-v4/PoolManager.sol/PoolManager.json`.

```bash
FOUNDRY_PROFILE=v4 forge build
forge test --no-match-path 'test/fork/*'
```

## Unichain fork tests

The fork suite uses real Aqua and PoolManager deployments with USDC/WETH at block
58230608. It covers direct swaps, both Uniswap directions, time-dependent quotes
and docking. Network access is required; `UNICHAIN_RPC_URL` overrides the public RPC.

```bash
forge test --match-path test/fork/UnichainFork.t.sol
```

## Local demo

Run anvil in one terminal, then run the demo script from `contracts` in another:

```bash
anvil --port 8546 --fork-url https://mainnet.unichain.org --fork-block-number 58230608 --chain-id 130
```

```bash
RPC=http://127.0.0.1:8546 ./scripts/demo.sh
```

`script/Deploy.s.sol` deploys the router, lens, hook and swap helper.
`script/Ship.s.sol` derives the start weight, ships a position and registers its route.
`script/Swap.s.sol` fills it directly or through Uniswap. The runbook also advances
fork time. Deployment and position JSON go in `deployments/`; large amounts,
weights and prices are written as decimal strings for JavaScript readers.

## Web app

The Next.js and viem app talks to the local Unichain fork using anvil's maker and
taker accounts. Create derives the starting value split, previews the path, ships
to Aqua and registers the Uniswap route. Position shows target versus actual
value share, balances, earned fees and swap history, and lets the maker dock.

After building the contracts and running the local demo:

```bash
cd web
npm install
npm run dev
```

Open http://localhost:3000. The predev script synchronizes contract ABIs and
deployment JSON into the ignored `web/generated/` directory. Use `npm run sync`
after changing a deployment or shipping a position from the contract scripts.

Demo tools adds fork time travel, an arbitrage loop and direct or Uniswap swaps.
The navigation includes `/demo` alongside Create and Position.
