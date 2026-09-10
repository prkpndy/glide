import { formatUnits } from "viem";
import { WAD } from "./config";

export function fmtAmount(value: bigint, decimals: number, digits = 4): string {
  const s = formatUnits(value, decimals);
  const [int, frac = ""] = s.split(".");
  const intFmt = Number(int).toLocaleString("en-US");
  const f = frac.slice(0, digits).replace(/0+$/, "");
  return f ? `${intFmt}.${f}` : intFmt;
}

export function fmtPct(wad: bigint, digits = 1): string {
  return `${(Number(wad) / 1e16).toFixed(digits)}%`;
}

export function fmtWad(wad: bigint, digits = 4): string {
  return (Number(wad) / 1e18).toFixed(digits);
}

export function pctToWad(pct: number): bigint {
  return BigInt(Math.round(pct * 1e16));
}

export function wadToPct(wad: bigint): number {
  return Number(wad) / 1e16;
}

export function short(addr: string): string {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

export function fmtDuration(seconds: number): string {
  if (seconds < 3600) return `${Math.round(seconds / 60)}m`;
  if (seconds < 86400) return `${(seconds / 3600).toFixed(1).replace(/\.0$/, "")}h`;
  return `${(seconds / 86400).toFixed(1).replace(/\.0$/, "")}d`;
}

export function fmtTime(ts: number): string {
  return new Date(ts * 1000).toLocaleString("en-US", { hour12: false });
}

export { WAD };
