import { encodeAbiParameters, erc20Abi, maxUint256, zeroAddress, type Address, type Hex } from "viem";
import { AquaAbi, GlideHookAbi, GlideLensAbi, GlideSwapVMRouterAbi, PoolSwapTestAbi } from "@/generated/abis";
import { publicClient, rpc, type Wallet } from "./clients";
import { deployment, WAD, type GlideParams } from "./config";

export const MIN_WEIGHT = 10n ** 16n;
export const MAX_WEIGHT = 99n * 10n ** 16n;
const MIN_SQRT_PRICE = 4295128739n;
const MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342n;

function d() {
  if (!deployment) throw new Error("no deployment for this chain; run contracts/scripts/demo.sh then npm run sync");
  return deployment;
}

// ---- pure helpers (mirror GlideSwap.weightAt and WeightedMath.spotOutPerIn) ----

export function weightAt(p: GlideParams, t: number): bigint {
  if (t <= p.start) return p.wA0;
  const end = p.start + p.duration;
  if (t >= end) return p.wA1;
  const elapsed = BigInt(t - p.start);
  const dur = BigInt(p.duration);
  return p.wA1 >= p.wA0 ? p.wA0 + ((p.wA1 - p.wA0) * elapsed) / dur : p.wA0 - ((p.wA0 - p.wA1) * elapsed) / dur;
}

export function deriveStartWeight(valueA: bigint, valueB: bigint): bigint {
  if (valueA + valueB === 0n) return WAD / 2n;
  let w = (valueA * WAD) / (valueA + valueB);
  if (w < MIN_WEIGHT) w = MIN_WEIGHT;
  if (w > MAX_WEIGHT) w = MAX_WEIGHT;
  return w;
}

/** value of `amount` raw units at `price` (WAD USD per whole token), in WAD USD */
export function usdValue(amount: bigint, price: bigint, decimals: number): bigint {
  return (amount * price) / 10n ** BigInt(decimals);
}

export function valueShareA(valueA: bigint, valueB: bigint): bigint {
  return valueA + valueB === 0n ? 0n : (valueA * WAD) / (valueA + valueB);
}

/** raw tokenB per raw tokenA at the margin, WAD */
export function spotBPerA(balA: bigint, wA: bigint, balB: bigint): bigint {
  if (balA === 0n || wA === WAD) return 0n;
  return (balB * wA * WAD) / (balA * (WAD - wA));
}

// ---- reads ----

export type TokenMeta = { address: Address; symbol: string; decimals: number };
const metaCache = new Map<string, TokenMeta>();

export async function tokenMeta(address: Address): Promise<TokenMeta> {
  const cached = metaCache.get(address.toLowerCase());
  if (cached) return cached;
  const [symbol, decimals] = await Promise.all([
    publicClient.readContract({ address, abi: erc20Abi, functionName: "symbol" }),
    publicClient.readContract({ address, abi: erc20Abi, functionName: "decimals" }),
  ]);
  const meta = { address, symbol, decimals };
  metaCache.set(address.toLowerCase(), meta);
  return meta;
}

export function balanceOf(token: Address, owner: Address) {
  return publicClient.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [owner] });
}

export async function chainNow(): Promise<{ timestamp: number; block: bigint }> {
  const b = await publicClient.getBlock();
  return { timestamp: Number(b.timestamp), block: b.number };
}

export function poolKey() {
  const dep = d();
  return {
    currency0: dep.tokenA,
    currency1: dep.tokenB,
    fee: dep.poolFee,
    tickSpacing: dep.tickSpacing,
    hooks: dep.hook,
  } as const;
}

function lensParams(p: GlideParams) {
  return {
    tokenA: p.tokenA,
    tokenB: p.tokenB,
    feeBps: p.feeBps,
    start: p.start,
    duration: p.duration,
    wA0: p.wA0,
    wA1: p.wA1,
    salt: p.salt,
  } as const;
}

export type Order = { maker: Address; traits: bigint; data: Hex };

export async function buildOrder(maker: Address, p: GlideParams): Promise<Order> {
  const o = await publicClient.readContract({
    address: d().lens,
    abi: GlideLensAbi,
    functionName: "buildOrder",
    args: [maker, lensParams(p)],
  });
  return { maker: o.maker, traits: o.traits, data: o.data };
}

export function orderHash(maker: Address, p: GlideParams) {
  return publicClient.readContract({ address: d().lens, abi: GlideLensAbi, functionName: "orderHash", args: [maker, lensParams(p)] });
}

export type PositionState = { active: boolean; balanceA: bigint; balanceB: bigint; wA: bigint; spotBPerA: bigint };

export async function readState(maker: Address, p: GlideParams): Promise<PositionState> {
  const s = await publicClient.readContract({ address: d().lens, abi: GlideLensAbi, functionName: "state", args: [maker, lensParams(p)] });
  return { active: s.active, balanceA: s.balanceA, balanceB: s.balanceB, wA: s.wA, spotBPerA: s.spotBPerA };
}

export async function quote(maker: Address, p: GlideParams, isExactIn: boolean, aToB: boolean, amount: bigint) {
  const [amountIn, amountOut] = await publicClient.readContract({
    address: d().lens,
    abi: GlideLensAbi,
    functionName: "quote",
    args: [maker, lensParams(p), isExactIn, aToB, amount],
  });
  return { amountIn, amountOut };
}

export async function routeFor() {
  const [maker] = await publicClient.readContract({ address: d().hook, abi: GlideHookAbi, functionName: "route", args: [poolKey()] });
  return maker;
}

// ---- writes ----

async function wait(hash: Hex) {
  const r = await publicClient.waitForTransactionReceipt({ hash });
  if (r.status !== "success") throw new Error(`transaction ${hash} reverted`);
  return r;
}

async function ensureAllowance(wallet: Wallet, token: Address, spender: Address, amount: bigint) {
  const owner = wallet.account.address;
  const allowance = await publicClient.readContract({ address: token, abi: erc20Abi, functionName: "allowance", args: [owner, spender] });
  if (allowance >= amount) return;
  const hash = await wallet.writeContract({ address: token, abi: erc20Abi, functionName: "approve", args: [spender, maxUint256] });
  await wait(hash);
}

export async function ship(wallet: Wallet, p: GlideParams, amountA: bigint, amountB: bigint, onStep?: (s: string) => void) {
  const dep = d();
  const maker = wallet.account.address;
  onStep?.("approving tokens for Aqua");
  await ensureAllowance(wallet, p.tokenA, dep.aqua, amountA);
  await ensureAllowance(wallet, p.tokenB, dep.aqua, amountB);

  onStep?.("shipping strategy to Aqua");
  const strategy = await publicClient.readContract({ address: dep.lens, abi: GlideLensAbi, functionName: "encodeShipStrategy", args: [maker, lensParams(p)] });
  const shipHash = await wallet.writeContract({
    address: dep.aqua,
    abi: AquaAbi,
    functionName: "ship",
    args: [dep.router, strategy, [p.tokenA, p.tokenB], [amountA, amountB]],
  });
  await wait(shipHash);

  onStep?.("pointing the Uniswap pool at the position");
  const order = await buildOrder(maker, p);
  const routeHash = await wallet.writeContract({ address: dep.hook, abi: GlideHookAbi, functionName: "registerRoute", args: [poolKey(), order] });
  await wait(routeHash);

  return { shipHash, routeHash, orderHash: await orderHash(maker, p) };
}

export async function dock(wallet: Wallet, p: GlideParams) {
  const dep = d();
  const h = await orderHash(wallet.account.address, p);
  const hash = await wallet.writeContract({ address: dep.aqua, abi: AquaAbi, functionName: "dock", args: [dep.router, h, [p.tokenA, p.tokenB]] });
  await wait(hash);
  const routeMaker = await routeFor();
  if (routeMaker.toLowerCase() === wallet.account.address.toLowerCase()) {
    const h2 = await wallet.writeContract({ address: dep.hook, abi: GlideHookAbi, functionName: "clearRoute", args: [poolKey()] });
    await wait(h2);
  }
  return hash;
}

export async function swapDirect(wallet: Wallet, maker: Address, p: GlideParams, aToB: boolean, amountIn: bigint, minOut: bigint) {
  const dep = d();
  const tokenIn = aToB ? p.tokenA : p.tokenB;
  await ensureAllowance(wallet, tokenIn, dep.router, amountIn);
  const order = await buildOrder(maker, p);
  const takerData = await publicClient.readContract({
    address: dep.lens,
    abi: GlideLensAbi,
    functionName: "takerData",
    args: [true, aToB, minOut, zeroAddress, 0],
  });
  const hash = await wallet.writeContract({ address: dep.router, abi: GlideSwapVMRouterAbi, functionName: "swap", args: [order, amountIn, takerData] });
  await wait(hash);
  return hash;
}

export async function swapViaUniswap(wallet: Wallet, aToB: boolean, amountIn: bigint, minOut: bigint) {
  const dep = d();
  const tokenIn = aToB ? dep.tokenA : dep.tokenB;
  await ensureAllowance(wallet, tokenIn, dep.swapRouter, amountIn);
  const hash = await wallet.writeContract({
    address: dep.swapRouter,
    abi: PoolSwapTestAbi,
    functionName: "swap",
    args: [
      poolKey(),
      { zeroForOne: aToB, amountSpecified: -amountIn, sqrtPriceLimitX96: aToB ? MIN_SQRT_PRICE + 1n : MAX_SQRT_PRICE - 1n },
      { takeClaims: false, settleUsingBurn: false },
      encodeAbiParameters([{ type: "uint256" }], [minOut]),
    ],
  });
  await wait(hash);
  return hash;
}

// ---- history ----

export type SwapEvent = {
  block: bigint;
  timestamp: number;
  txHash: Hex;
  taker: Address;
  tokenIn: Address;
  tokenOut: Address;
  amountIn: bigint;
  amountOut: bigint;
};

const blockTimeCache = new Map<bigint, number>();

export async function swapsFor(hash: Hex): Promise<SwapEvent[]> {
  const dep = d();
  const logs = await publicClient.getContractEvents({
    address: dep.router,
    abi: GlideSwapVMRouterAbi,
    eventName: "Swapped",
    fromBlock: BigInt(dep.deployedAtBlock),
    toBlock: "latest",
  });
  const mine = logs.filter((l) => l.args.orderHash === hash);
  const out: SwapEvent[] = [];
  for (const l of mine) {
    let ts = blockTimeCache.get(l.blockNumber);
    if (ts === undefined) {
      ts = Number((await publicClient.getBlock({ blockNumber: l.blockNumber })).timestamp);
      blockTimeCache.set(l.blockNumber, ts);
    }
    out.push({
      block: l.blockNumber,
      timestamp: ts,
      txHash: l.transactionHash,
      taker: l.args.taker!,
      tokenIn: l.args.tokenIn!,
      tokenOut: l.args.tokenOut!,
      amountIn: l.args.amountIn!,
      amountOut: l.args.amountOut!,
    });
  }
  return out;
}

// ---- fork time travel ----

export async function advanceTime(seconds: number) {
  await rpc("evm_increaseTime", [seconds]);
  await rpc("evm_mine", []);
}
