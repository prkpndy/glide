"use client";

import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { parseUnits } from "viem";
import WeightChart from "@/components/WeightChart";
import { deployment, savePosition, WAD, type GlideParams } from "@/lib/config";
import { balanceOf, deriveStartWeight, schedule, SHAPES, ship, spotBPerA, tokenMeta, usdValue, type Shape, type TokenMeta } from "@/lib/glide";
import { fmtAmount, fmtPct, pctToWad, wadToPct } from "@/lib/format";
import { useSession } from "@/lib/session";

export default function CreatePage() {
  const s = useSession();
  const router = useRouter();
  const [metaA, setMetaA] = useState<TokenMeta>();
  const [metaB, setMetaB] = useState<TokenMeta>();
  const [walletA, setWalletA] = useState(0n);
  const [walletB, setWalletB] = useState(0n);

  const [amountA, setAmountA] = useState("3000");
  const [amountB, setAmountB] = useState("5");
  const [priceA, setPriceA] = useState("1");
  const [priceB, setPriceB] = useState("3000");
  const [endPct, setEndPct] = useState(70);
  const [hours, setHours] = useState(24);
  const [feePct, setFeePct] = useState("0.3");
  const [shape, setShape] = useState<Shape>("linear");

  const [busy, setBusy] = useState<string>();
  const [error, setError] = useState<string>();

  useEffect(() => {
    if (!deployment || !s.ready) return;
    tokenMeta(deployment.tokenA).then(setMetaA).catch(() => {});
    tokenMeta(deployment.tokenB).then(setMetaB).catch(() => {});
  }, [s.ready]);

  useEffect(() => {
    if (!deployment || !s.ready) return;
    balanceOf(deployment.tokenA, s.address).then(setWalletA).catch(() => {});
    balanceOf(deployment.tokenB, s.address).then(setWalletB).catch(() => {});
  }, [s.address, s.tick, s.ready]);

  const derived = useMemo(() => {
    if (!metaA || !metaB) return undefined;
    try {
      const a = parseUnits(amountA || "0", metaA.decimals);
      const b = parseUnits(amountB || "0", metaB.decimals);
      const pA = parseUnits(priceA || "0", 18);
      const pB = parseUnits(priceB || "0", 18);
      const valueA = usdValue(a, pA, metaA.decimals);
      const valueB = usdValue(b, pB, metaB.decimals);
      const wA0 = deriveStartWeight(valueA, valueB);
      const wA1 = pctToWad(endPct);
      const feeBps = Math.round(Number(feePct || "0") * 1e5); // percent -> 1e7 units
      const start = s.now;
      const sched = schedule(shape, wA0, wA1, hours * 3600);
      const params: GlideParams = { tokenA: metaA.address, tokenB: metaB.address, feeBps, start, duration: hours * 3600, wA0, wA1, salt: BigInt(start), ...sched };
      // pool spot (B per A) vs reference, in raw units
      const spot = a > 0n && b > 0n ? spotBPerA(a, wA0, b) : 0n;
      const ref = pB > 0n ? (pA * 10n ** BigInt(metaB.decimals) * WAD) / (pB * 10n ** BigInt(metaA.decimals)) : 0n;
      const drift = ref > 0n ? Number(((spot - ref) * 10000n) / ref) / 100 : 0;
      return { a, b, pA, pB, valueA, valueB, wA0, wA1, params, spot, ref, drift, feeBps };
    } catch {
      return undefined;
    }
  }, [metaA, metaB, amountA, amountB, priceA, priceB, endPct, hours, feePct, shape, s.now]);

  const problems: string[] = [];
  if (derived) {
    if (derived.a === 0n || derived.b === 0n) problems.push("both sides need a non-zero amount: a weighted curve is undefined with an empty reserve");
    if (derived.a > walletA) problems.push(`wallet holds only ${fmtAmount(walletA, metaA!.decimals)} ${metaA!.symbol}`);
    if (derived.b > walletB) problems.push(`wallet holds only ${fmtAmount(walletB, metaB!.decimals)} ${metaB!.symbol}`);
    if (hours < 1) problems.push("window must be at least one hour");
    if (derived.feeBps < 0 || derived.feeBps >= 10_000_000) problems.push("fee must be between 0% and 100%");
  }
  if (s.role !== "maker") problems.push("switch to the maker account in the header to ship");

  async function onShip() {
    if (!s.ready || !derived || !metaA || !metaB) return;
    setError(undefined);
    setBusy("starting");
    try {
      const { orderHash } = await ship(s.wallet, derived.params, derived.a, derived.b, setBusy);
      savePosition({ maker: s.address, params: derived.params, amountA: derived.a, amountB: derived.b, priceA: derived.pA, priceB: derived.pB });
      setBusy(`shipped ${orderHash.slice(0, 10)}…`);
      await s.refresh();
      router.push("/position");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setBusy(undefined);
    }
  }

  if (!deployment) {
    return (
      <div className="empty">
        No deployment for this chain. Run <span className="mono">contracts/scripts/demo.sh</span> against an anvil fork, then <span className="mono">npm run sync</span>.
      </div>
    );
  }

  return (
    <>
      <div className="hero">
        <h1>Set a target. Let the market rebalance you. Get paid for it.</h1>
        <p>
          Keep your tokens in your own wallet, publish a glide path for their value split, and let arbitrage walk your wallet along it while paying
          you a fee on every trade. Positions live on 1inch Aqua; a Uniswap v4 pool forwards the whole market to them.
        </p>
      </div>

      <div className="grid side">
        <div className="card">
          <h2>New position</h2>

          <div className="row">
            <div className="field">
              <label>
                <span>{metaA?.symbol ?? "token A"} exposed</span>
                <span className="mono">wallet {metaA ? fmtAmount(walletA, metaA.decimals, 2) : "…"}</span>
              </label>
              <input type="text" value={amountA} onChange={(e) => setAmountA(e.target.value)} />
            </div>
            <div className="field">
              <label>
                <span>{metaB?.symbol ?? "token B"} exposed</span>
                <span className="mono">wallet {metaB ? fmtAmount(walletB, metaB.decimals, 2) : "…"}</span>
              </label>
              <input type="text" value={amountB} onChange={(e) => setAmountB(e.target.value)} />
            </div>
          </div>

          <div className="row">
            <div className="field">
              <label>
                <span>{metaA?.symbol ?? "A"} price (USD)</span>
              </label>
              <input type="text" value={priceA} onChange={(e) => setPriceA(e.target.value)} />
            </div>
            <div className="field">
              <label>
                <span>{metaB?.symbol ?? "B"} price (USD)</span>
              </label>
              <input type="text" value={priceB} onChange={(e) => setPriceB(e.target.value)} />
            </div>
          </div>

          <div className="field">
            <label>
              <span>end {metaA?.symbol ?? "A"} value share</span>
              <span className="mono">{endPct}%</span>
            </label>
            <input type="range" min={1} max={99} value={endPct} onChange={(e) => setEndPct(Number(e.target.value))} />
          </div>

          <div className="field">
            <label>
              <span>path shape</span>
              <span className="mono">{SHAPES.find((x) => x.id === shape)?.hint}</span>
            </label>
            <select value={shape} onChange={(e) => setShape(e.target.value as Shape)}>
              {SHAPES.map((x) => (
                <option key={x.id} value={x.id}>
                  {x.label}
                </option>
              ))}
            </select>
          </div>

          <div className="row">
            <div className="field">
              <label>
                <span>window (hours)</span>
              </label>
              <input type="number" min={1} value={hours} onChange={(e) => setHours(Number(e.target.value))} />
            </div>
            <div className="field">
              <label>
                <span>taker fee (%)</span>
              </label>
              <input type="text" value={feePct} onChange={(e) => setFeePct(e.target.value)} />
            </div>
          </div>

          {derived && metaA && metaB && (
            <div className="callout">
              Start share is derived from your value split so the position opens at the market price: <b>{fmtPct(derived.wA0)}</b> {metaA.symbol} /{" "}
              <b>{fmtPct(WAD - derived.wA0)}</b> {metaB.symbol}. Pool price vs your reference:{" "}
              <b className={Math.abs(derived.drift) > 1 ? "warn" : "good"}>{derived.drift >= 0 ? "+" : ""}{derived.drift.toFixed(2)}%</b>.
            </div>
          )}

          {problems.map((p) => (
            <div key={p} className="callout" style={{ borderColor: "var(--warn)" }}>
              {p}
            </div>
          ))}
          {error && <div className="log err">{error}</div>}

          <div className="btn-row" style={{ marginTop: 6 }}>
            <button className="btn" disabled={!s.ready || !derived || problems.length > 0 || !!busy} onClick={onShip}>
              {busy ? busy : "Approve & ship"}
            </button>
          </div>
          <p className="muted" style={{ marginTop: 10, fontSize: 12 }}>
            Ship records virtual balances on Aqua and points the Uniswap pool at your position. No tokens move until someone trades.
            {shape !== "linear" && " Non-linear shapes use the piecewise opcode with a 12-point schedule."}
          </p>
        </div>

        <div className="card">
          <h2>
            Glide path <span className="tag">{metaA?.symbol ?? "A"} weight over time</span>
          </h2>
          {derived && metaA ? (
            <>
              <WeightChart params={derived.params} symbolA={metaA.symbol} />
              <div className="stats" style={{ marginTop: 14 }}>
                <div className="stat">
                  <div className="k">start</div>
                  <div className="v">{wadToPct(derived.wA0).toFixed(1)}%</div>
                  <div className="s">{metaA.symbol} value share</div>
                </div>
                <div className="stat">
                  <div className="k">end</div>
                  <div className="v">{endPct}%</div>
                  <div className="s">{metaA.symbol} value share</div>
                </div>
                <div className="stat">
                  <div className="k">exposed value</div>
                  <div className="v">${fmtAmount(derived.valueA + derived.valueB, 18, 0)}</div>
                  <div className="s">at your reference prices</div>
                </div>
                <div className="stat">
                  <div className="k">to convert</div>
                  <div className="v">${fmtAmount(((derived.valueA + derived.valueB) * (derived.wA1 > derived.wA0 ? derived.wA1 - derived.wA0 : derived.wA0 - derived.wA1)) / WAD, 18, 0)}</div>
                  <div className="s">{derived.wA1 > derived.wA0 ? `${metaB?.symbol} → ${metaA.symbol}` : `${metaA.symbol} → ${metaB?.symbol}`} over {hours}h</div>
                </div>
              </div>
            </>
          ) : (
            <div className="empty">loading tokens…</div>
          )}
        </div>
      </div>
    </>
  );
}
