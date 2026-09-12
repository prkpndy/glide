# Uniswap Developer Feedback

Project: Glide (ETHOnline 2026). What we built on Uniswap: a v4 hook, `contracts/src/hooks/GlideHook.sol`, that uses
`beforeSwap` + `beforeSwapReturnDelta` custom accounting to fill swaps from an external, self-custodial liquidity source
(1inch Aqua) so the pool itself holds no liquidity. Tested with the real PoolManager on a Unichain fork.

## What went well

- **Custom accounting is the right primitive.** `take` the input, do anything, `sync`/`transfer`/`settle` the output,
  return a `BeforeSwapDelta` that consumes the specified amount. Once understood, a full "the hook is the venue" swap is
  about twenty lines. `CustomCurveHook.sol` in v4-core's test folder was the clearest reference we found and we copied
  its delta sign convention verbatim.
- **Hook address flags via CREATE2 mining** worked first time with `HookMiner`, both in tests and in a broadcast script
  through the canonical deterministic deployer.
- **`PoolSwapTest`** was invaluable for demos: it lets a script or a frontend swap through the PoolManager without
  Permit2 and the Universal Router.

## What was confusing, missing, or hard

1. **`take` before settle needs the PoolManager's aggregate float.** A custom-accounting hook that needs the swapper's
   input tokens *during* `beforeSwap` (to hand them to an external venue) has to `take` them before the swapper has
   settled. That works on a live PoolManager because other pools' reserves are there, and fails on a fresh, empty
   PoolManager with a plain ERC20 transfer underflow that gives no hint about the cause. It took a while to realise
   the failure was flash accounting, not our code. The custom-accounting guide could say explicitly: "`take` in
   `beforeSwap` draws on the manager's total balance of that currency; the swapper's repayment is enforced at unlock,
   not before your hook runs." A dedicated "external liquidity / hook-as-venue" example would help too.
2. **`BaseHook` moved.** The docs and most tutorials import `BaseHook` from `v4-periphery/src/utils/BaseHook.sol`, but
   the current `v4-periphery` main has no `BaseHook.sol` in `src/` at all. We ended up implementing `IHooks` directly
   with reverting stubs and calling `Hooks.validateHookPermissions` in the constructor. A note in the docs about where
   `BaseHook` lives now (or that it was removed) would save an hour.
3. **Compiler pins.** `PoolManager.sol` pins `solc 0.8.26` exactly and does not compile under `via_ir`
   (stack too deep in Yul). Any project that also depends on code pinned to a newer compiler, as 1inch SwapVM is pinned
   to `0.8.30`, cannot compile the two in one Foundry unit. We had to build v4-core in a separate Foundry profile and
   load the PoolManager bytecode from its artifact in tests. Foundry's `compilation_restrictions` did not resolve it
   for us. A caret pragma on `PoolManager.sol`, or a documented "use the artifact" pattern, would help integrators.
4. **`Deployers.sol` drags in `PoolManager.sol`.** Because of the pin above, the otherwise excellent test helper cannot
   be imported next to newer-solc code. A `Deployers` variant that takes an already-deployed `IPoolManager` would make
   the helpers reusable in mixed-version repos.
5. **Delta sign convention is under-documented.** The guide explains fee-taking deltas well, but the "consume the
   whole specified amount and provide the unspecified amount yourself" case is only shown in test code. Two sentences
   plus the `toBeforeSwapDelta(+amountIn, -amountOut)` line in the guide would cover the most powerful use of the
   feature.
6. **Reverts are wrapped twice.** A revert inside `beforeSwap` surfaces as `WrappedError(hook, selector, innerData,
   ...)`, and inside that our SwapVM revert data. Debuggable with `forge test -vvvv`, but a small helper to unwrap
   hook reverts in forge-std or the docs would be welcome.

## Suggestions

- Add an "external venue hook" starter alongside the fee and custom-curve examples: take input, fill elsewhere,
  settle output, return delta, plus the flash-accounting caveat above.
- Ship `HookMiner` in `src/` (or a small package) since every hook needs it in both tests and deploy scripts.
- Keep one compiler-agnostic path for integrators: relax the exact pragma on `PoolManager.sol` or publish artifacts.

## Where to look in our repo

- Hook: `contracts/src/hooks/GlideHook.sol` (`beforeSwap`, `registerRoute`, `getHookPermissions`)
- Unit test with a freshly deployed PoolManager: `contracts/test/GlideHook.t.sol`
- Fork test with the real Unichain PoolManager: `contracts/test/fork/UnichainFork.t.sol`
- Deploy script with mined hook address and pool initialisation: `contracts/script/Deploy.s.sol`
- Separate build profile for v4-core: `contracts/foundry.toml` (`[profile.v4]`) and `contracts/test/utils/V4Artifacts.sol`
