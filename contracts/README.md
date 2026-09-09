# Glide contracts

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
