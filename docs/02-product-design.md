# Glide: Product Design

Non-technical but detailed description of what we are building for ETHOnline 2026. A separate technical design doc will follow.

Working name: **Glide**. Tagline candidate: *"Rebalance your wallet by letting the market do it, and get paid for it."*

---

## 1. The problem

Suppose you hold 10 ETH and want to be 70% in USDC by the end of the month. Today you have three bad options:

1. **Sell it all now.** You eat slippage on a big trade and take full timing risk.
2. **Sell it in slices by hand** or with a DCA bot. Every slice pays swap fees and slippage to someone else, and you need a bot or a custodial service.
3. **Deposit into an AMM pool** and let arbitrage rebalance you. But then the pool owns your tokens, you cannot pick a target split, and it never changes over time.

In every case you are the one paying. The people who actually move the market, arbitrageurs, are the ones who get paid.

## 2. The idea

Glide flips who pays whom. You keep your tokens in your own wallet and publish a **glide path**: a starting split, an ending split, and a time window. Example: "ETH/USDC, 100/0 now, 30/70 in 30 days."

Glide prices your wallet like an AMM whose target split slides along that path. Whenever the market price moves, or your wallet drifts from the current target, a trader can profit by swapping against you. That trade nudges your wallet back toward the target, and **the trader pays you a fee for the privilege**.

Over the window, arbitrageurs gradually convert your wallet exactly along the path you asked for. You paid no slippage and no bot fees. You collected fees instead.

Because it runs on 1inch Aqua, the tokens never leave your wallet until the moment a trade executes. There is no deposit, no vault, no pool contract holding your money.

## 3. Who it is for

| User | What they want | What Glide gives them |
|---|---|---|
| **Maker** (a holder, treasury, or DAO) | Convert or rebalance a position over time without paying slippage or trusting a bot | A self-custodial position that arbitrage rebalances for them, earning fees |
| **Taker** (arbitrageur, aggregator, or any trader) | Cheap liquidity when the position is off-target | A standard swap, reachable through 1inch Aqua or a normal Uniswap pool |

The maker is the star of the product. Takers do not need to know Glide exists; they just see a good price.

## 4. How it works, in plain language

### 4.1 Creating a position (maker)

1. Connect a wallet holding both tokens. Both sides must be non-zero: a weighted curve is undefined with an empty reserve, so a maker who holds only ETH first needs a little USDC (or the reverse).
2. Choose the pair, e.g. ETH and USDC, and how much of each to expose.
3. Enter reference prices. The **start split** is *derived* from the value split of the exposed amounts, so the position opens exactly at the market price. If it were chosen freely, arbitrage would take the gap from the maker in the first trade.
4. Choose the **end split** and the **window**. A preview chart shows the path.
5. Choose a **fee** takers pay on each trade, e.g. 0.30%.
6. Approve the tokens once and click **Ship**. The position is live. Tokens remain in the wallet.

Weights are clamped to the 1% to 99% range on both ends.

### 4.2 While the position is live

- At any moment the position has a **current target split** computed from the clock and the glide path.
- The position quotes prices like a weighted AMM at that target. If the wallet holds too much ETH relative to the target, ETH is offered slightly cheap; if too little, ETH is bid slightly rich.
- Traders swap against it. Each swap pulls tokens from the maker's wallet and pushes the trader's tokens into it, plus the fee.
- Nothing runs in the background. There is no keeper. The clock is read on-chain at swap time.

### 4.3 Ending or changing a position

- The maker can **dock** the position at any time. Trading stops instantly. No withdrawal step, because the tokens were never anywhere else.
- To change parameters, dock and ship a new one. This is how Aqua works and we keep it simple.

### 4.4 Reaching the position through Uniswap

Most trading volume flows through Uniswap routers, aggregators, and interfaces. We create a Uniswap v4 pool whose only job is to forward trades to the Glide position. The pool holds no liquidity itself. Anyone swapping through Uniswap gets filled from the maker's wallet, and the maker earns the fee. This is the Uniswap track deliverable and it makes the position discoverable by the whole market.

## 5. What the demo shows

Target length 3 minutes. Two screens: the Glide web app and a terminal or block explorer for the fork.

1. **Setup (20s).** Maker wallet holds 10 ETH and 0 USDC. Show the balance.
2. **Create (40s).** Build a position in the app: ETH/USDC, 100/0 to 30/70, over a 24-hour window compressed to a few minutes on the fork. Ship it. Wallet balance unchanged.
3. **Arbitrage (60s).** Advance the fork clock. The target split moves. Run a taker script that swaps USDC for ETH at the Glide price. Show the maker wallet: less ETH, more USDC, fee received. Repeat two or three times with the chart animating toward the target.
4. **Uniswap route (40s).** Perform a swap through the Uniswap v4 PoolManager on the same pool. Show that the maker wallet changed, proving the hook routed into the position.
5. **Close (20s).** Show the position summary: path completed, fees earned, zero deposits ever made.

Everything on screen is a real on-chain transaction on a mainnet fork. That satisfies 1inch's "onchain execution of token transfers" rule.

## 6. The web app

Yes, we build a frontend. It is what makes "your tokens never leave your wallet" visible, and judges score usability and wow factor.

### Pages

**Create position**
- Pair selector (two tokens).
- Start split and end split sliders.
- Window start and end.
- Fee input.
- Optional oracle guardrail toggle.
- Live chart: target split over time, and the implied price skew at the current wallet balance.
- Approve and Ship buttons.

**Position dashboard**
- Position card: pair, path, window, fee, status.
- Progress: elapsed time, current target split, actual wallet split, drift.
- Chart: target path line with actual wallet split plotted over it as trades occur.
- Fees earned to date.
- Trade history: each swap with direction, amounts, fee, tx link.
- Dock button.

**Taker view (demo only)**
- A simple "swap against this position" form that quotes and executes, so the demo does not rely solely on scripts. Also a "swap via Uniswap" button that routes through the hook pool.

### Scope discipline
- Single wallet, single position at a time in the UI is enough.
- No mobile layout work.
- No token search; a fixed list of two or three tokens from the fork.
- Clear visual language: the wallet balance must be visible on every screen.

## 7. What we are not building

- No support for more than two tokens per position.
- No non-linear glide paths (only linear interpolation between start and end split). Additive later: a second opcode with a piecewise schedule.
- No price guardrail opcode. `RequireMinRate` from stock SwapVM can be added to the program later without touching the curve.
- No keeper, bot, or off-chain service.
- No mainnet deployment. Fork only, per the 1inch rules.
- No fee sharing, governance, or token.
- No Uniswap CCA or v3 integration. v4 hook only.

## 8. Why judges should care

**1inch judges** get exactly what they asked for: a sophisticated position that cannot be expressed with stock SwapVM opcodes, implemented as new instructions in a redeployed router, running on the official Aqua registry, with real transfers on a fork and a clean commit history. It also shows off Aqua's core pitch, self-custody, better than a plain AMM would.

**Uniswap judges** get a real v4 hook using custom accounting, a pattern few hackathon teams attempt, plus a FEEDBACK.md with concrete notes from building it.

**General judges** get an understandable story: "I set a target, the market rebalanced me, and I got paid." One sentence, one chart, one wallet balance going the right way.

## 9. Risks and how we handle them

| Risk | Mitigation |
|---|---|
| Weighted-curve math is harder than constant product | Reuse well-known fixed-point pow math. Test against 1inch's CoreInvariants suite from day one. |
| SwapVM invariants (symmetry, additivity, monotonicity) fail on our opcode | Design the opcode so the time-based target only changes between blocks, never within a swap. Round in the maker's favour everywhere. |
| Uniswap hook eats the schedule | It is isolated in its own folder and built last. If it slips, the 1inch submission still stands. |
| Frontend polish eats the schedule | Charts and forms only. Use a component library. No custom design system. |
| Fork drift or RPC flakiness during recording | Pin a fork block number. Record the video from a scripted run, not live. |
| Commit history rule | Commit small and often from the first hour. |

## 10. Implementation milestones

| Milestone | Deliverable |
|---|---|
| Foundation | Repository scaffold, product and technical design, SwapVM router building, first opcode stub |
| Curve | Weighted-curve math and glide-path opcode, unit tests and CoreInvariants |
| Settlement | Aqua ship/dock flow, taker script on the fork and end-to-end swaps |
| Integration | Uniswap hook and PoolManager tests, create and position pages, FEEDBACK.md |
| Submission | Demo recording, README and submission with a buffer before the deadline |

Trim unfinished scope before submission rather than extending the deadline.

## 11. Success criteria

- A maker can ship a glide-path position from the UI with tokens staying in their wallet.
- At least three arbitrage swaps on the fork move the wallet along the path and pay fees.
- One swap through the Uniswap v4 PoolManager fills from the same position.
- CoreInvariants tests pass for the new opcodes.
- Repo has a steady commit history, a README pointing at exact contracts, and a FEEDBACK.md.
- Video submitted before the deadline.
