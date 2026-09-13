import type { Address, Hex } from "viem";
import deploymentsJson from "@/generated/deployments.json";
import positionsJson from "@/generated/positions.json";

export const CHAIN_ID = Number(process.env.NEXT_PUBLIC_CHAIN_ID ?? "130");
export const RPC_URL = process.env.NEXT_PUBLIC_RPC_URL ?? "http://127.0.0.1:8546";
if (!["localhost", "127.0.0.1", "[::1]"].includes(new URL(RPC_URL).hostname)) {
  throw new Error("The demo accounts can only connect to a local Anvil RPC.");
}
export const DEMO_MAKER_PK = (process.env.NEXT_PUBLIC_DEMO_MAKER_PK ??
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d") as Hex;
export const DEMO_TAKER_PK = (process.env.NEXT_PUBLIC_DEMO_TAKER_PK ??
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a") as Hex;

export const WAD = 10n ** 18n;
export const FEE_DENOMINATOR = 10_000_000n; // FeeFlatIn uses 1e7 units

export type Deployment = {
  chainId: number;
  deployedAtBlock: number;
  deployer: Address;
  aqua: Address;
  poolManager: Address;
  weth: Address;
  usdc: Address;
  tokenA: Address;
  tokenB: Address;
  router: Address;
  lens: Address;
  hook: Address;
  swapRouter: Address;
  poolFee: number;
  tickSpacing: number;
};

export type GlideParams = {
  tokenA: Address;
  tokenB: Address;
  feeBps: number; // 1e7 units
  start: number;
  duration: number;
  wA0: bigint; // WAD
  wA1: bigint; // WAD
  salt: bigint;
  // optional piecewise schedule; empty = straight line. weights[0] == wA0, weights[last] == wA1, sum(durations) == duration
  weights: bigint[];
  durations: number[];
};

export type Position = {
  maker: Address;
  params: GlideParams;
  amountA: bigint;
  amountB: bigint;
  priceA: bigint; // WAD USD per whole token
  priceB: bigint;
};

const deployments = deploymentsJson as Record<string, Deployment>;
export const deployment: Deployment | undefined = deployments[String(CHAIN_ID)];

type RawPosition = {
  maker: string;
  amountA: string | number;
  amountB: string | number;
  priceA: string | number;
  priceB: string | number;
  params: {
    tokenA: string;
    tokenB: string;
    feeBps: string | number;
    start: string | number;
    duration: string | number;
    wA0: string | number;
    wA1: string | number;
    salt: string | number;
    weights?: (string | number)[];
    durations?: (string | number)[];
  };
};

function parsePosition(r: RawPosition): Position {
  return {
    maker: r.maker as Address,
    amountA: BigInt(r.amountA),
    amountB: BigInt(r.amountB),
    priceA: BigInt(r.priceA),
    priceB: BigInt(r.priceB),
    params: {
      tokenA: r.params.tokenA as Address,
      tokenB: r.params.tokenB as Address,
      feeBps: Number(r.params.feeBps),
      start: Number(r.params.start),
      duration: Number(r.params.duration),
      wA0: BigInt(r.params.wA0),
      wA1: BigInt(r.params.wA1),
      salt: BigInt(r.params.salt),
      weights: (r.params.weights ?? []).map((x) => BigInt(x)),
      durations: (r.params.durations ?? []).map((x) => Number(x)),
    },
  };
}

function serializePosition(p: Position): RawPosition {
  return {
    maker: p.maker,
    amountA: p.amountA.toString(),
    amountB: p.amountB.toString(),
    priceA: p.priceA.toString(),
    priceB: p.priceB.toString(),
    params: {
      tokenA: p.params.tokenA,
      tokenB: p.params.tokenB,
      feeBps: p.params.feeBps,
      start: p.params.start,
      duration: p.params.duration,
      wA0: p.params.wA0.toString(),
      wA1: p.params.wA1.toString(),
      salt: p.params.salt.toString(),
      weights: p.params.weights.map((x) => x.toString()),
      durations: p.params.durations,
    },
  };
}

const seeded = (positionsJson as Record<string, RawPosition>)[String(CHAIN_ID)];
export const seededPosition: Position | undefined = seeded ? parsePosition(seeded) : undefined;

const POSITION_KEY = `glide.position.${CHAIN_ID}`;

export function loadPosition(): Position | undefined {
  try {
    const s = localStorage.getItem(POSITION_KEY);
    if (s) return parsePosition(JSON.parse(s));
  } catch {
    /* no stored position */
  }
  return seededPosition;
}

export function savePosition(p: Position) {
  try {
    localStorage.setItem(POSITION_KEY, JSON.stringify(serializePosition(p)));
  } catch {
    /* storage unavailable */
  }
}

export function clearStoredPosition() {
  try {
    localStorage.removeItem(POSITION_KEY);
  } catch {
    /* storage unavailable */
  }
}
