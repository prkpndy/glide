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
