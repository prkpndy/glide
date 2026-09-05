# ETHOnline 2026: What We Are Building and Why

Working name for the project: **Glide**. Rename freely.

## The hackathon

- Event: ETHGlobal ETHOnline 2026, fully remote, September 4 to 16.
- **Submission deadline: Sunday, September 13, 2026 at 12:00 pm EDT. No late submissions.**
- One submission may select up to 3 partner prizes. We target two: 1inch and Uniswap Foundation.
- Required: public repo, 2 to 4 minute demo video at 720p or better, no AI voiceover, no phone recordings.
- General judging criteria: technicality, originality, practicality, usability, "wow factor". Partner prizes are judged asynchronously by the sponsor.

## 1inch

### What 1inch is

1inch launched in 2019 as a DEX aggregator. You ask to swap token A for token B and it splits the trade across many exchanges to find the best price. It has since shipped its own protocols: limit orders, and Fusion, where professional market makers called resolvers compete to fill user intents.

### What Aqua is

Aqua is 1inch's newest protocol and it inverts the normal AMM model.

- In Uniswap you deposit tokens into a pool contract and the pool owns them.
- In Aqua the tokens never leave your wallet. You approve the Aqua registry once, then call `ship` to declare "make X of token A and Y of token B available to this strategy".
- Aqua records only virtual balances. When a trader swaps, the strategy contract pulls tokens directly from your wallet and pushes the trader's tokens back in.
- The same wallet balance can back several strategies at once.
- Strategy contracts are called **apps**. Strategies are immutable once shipped; to change one you `dock` it and `ship` a new one.

Aqua is deployed at the same address on Ethereum, Base, Arbitrum, Optimism, Polygon, Unichain, and more.

### What SwapVM is

SwapVM is the main Aqua app. Instead of one contract per strategy, a maker writes a short bytecode program from a fixed set of opcodes: choose a curve (constant product, concentrated liquidity, limit order), add a Dutch auction, add fees, add an oracle adjuster, add a deadline. The SwapVM router executes the program on every swap and computes the output amount. Anyone can deploy their own router with extra opcodes.

### What 1inch asked for

"Build an Aqua App", $5,000 split $2,500 / $1,500 / $1,000.

- Create a custom Aqua app implementing a sophisticated DeFi position.
- Projects that use SwapVM score higher. Modifying opcodes and defining new instructions is explicitly allowed.
- Official Aqua and SwapVM contracts must be used. Redeploying a modified SwapVM router is fine.
- Onchain token transfers must be shown in the demo. Local forks are accepted.
- Proper git commit history. A single commit on the last day is disqualifying.

### What we will build for 1inch

A redeployed SwapVM router with new opcodes that express a **glide-path weighted position**: a two-token position whose target split moves over time, so the maker's wallet is gradually converted from one asset to the other by arbitrageurs while earning fees, with the tokens staying in the maker's own wallet the whole time. See `02-product-design.md`.

## Uniswap

### What Uniswap is

Uniswap is the largest decentralized exchange. Pools hold token pairs and price them by formula; anyone can trade or add liquidity. Version 4 moved all pools into a single PoolManager contract and introduced hooks.

### What hooks are

A hook is a contract attached to a pool that runs at fixed moments: before or after a swap, before or after liquidity changes. Hooks can charge dynamic fees, enforce rules, or, with a permission called custom accounting, take over the swap entirely and supply the output tokens themselves so the pool's own liquidity is bypassed. Permissions are encoded in the hook's address, so the deployer mines a matching address with CREATE2.

### What Uniswap asked for

"Best Uniswap Stack Contribution", three prizes of $1,000.

- Build on or integrate any part of the stack: v2, v3, or v4 AMM, the Uniswap API, Continuous Clearing Auctions, or tooling for the ecosystem. New v4 hooks are named as valid entries.
- Requirements: public open-source repo, a `FEEDBACK.md` file, the developer feedback form submitted with a link to that file, and a README that points to the exact contracts and lines that integrate Uniswap.

### What we will build for Uniswap

A v4 hook with custom accounting that turns a Uniswap pool into a doorway to the Glide position. When someone swaps through Uniswap, the hook takes their input, fills the trade against the SwapVM program via the official router, and settles the output back to the PoolManager. The pool holds no liquidity of its own.

## How the two fit together

One repo, two folders. The SwapVM router and program are the product and stand alone. The hook is a client of that product. If the hook slips, the 1inch submission is untouched. Everything runs on one mainnet fork of Unichain or Base, where Aqua, SwapVM, and Uniswap v4 all already exist.

## Reference links

- 1inch Aqua: https://github.com/1inch/aqua
- 1inch SwapVM: https://github.com/1inch/swap-vm
- Aqua SDK: https://github.com/1inch/sdks/tree/master/typescript/aqua
- Uniswap v4 hooks: https://developers.uniswap.org/docs/protocols/v4/concepts/hooks
- Uniswap custom accounting: https://developers.uniswap.org/docs/protocols/v4/guides/custom-accounting
- Uniswap feedback form: https://developers.uniswap.org/hackathon-feedback
- 1inch prize page: https://ethglobal.com/events/ethonline2026/prizes/1inch
- Uniswap prize page: https://ethglobal.com/events/ethonline2026/prizes/uniswap-foundation
