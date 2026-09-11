"use client";

import { useMemo, useState } from "react";
import Link from "next/link";
import WeightChart, { type ActualPoint } from "@/components/WeightChart";
import { FEE_DENOMINATOR, clearStoredPosition } from "@/lib/config";
import { dock, usdValue, valueShareA, weightAt } from "@/lib/glide";
import { fmtAmount, fmtDuration, fmtPct, fmtTime, short, wadToPct } from "@/lib/format";
import { useSession } from "@/lib/session";
import { usePosition } from "@/lib/usePosition";

export default function PositionPage() {
  const s = useSession();
  const v = usePosition();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();

  const calc = useMemo(() => {
    const { position, state, swaps, metaA, metaB } = v;
    if (!position || !state || !metaA || !metaB) return undefined;
    const p = position.params;
    const decA = metaA.decimals;
    const decB = metaB.decimals;

    const wNow = weightAt(p, s.now);
    const valueA = usdValue(state.balanceA, position.priceA, decA);
    const valueB = usdValue(state.balanceB, position.priceB, decB);
    const shareNow = valueShareA(valueA, valueB);

    // reference price and pool spot, both as whole B per whole A
    const ref = Number(position.priceA) / Number(position.priceB);
    const spot = (Number(state.spotBPerA) / 1e18) * 10 ** decA / 10 ** decB;
    const drift = ref > 0 ? ((spot - ref) / ref) * 100 : 0;

    // walk the swap history to plot the actual value share over time
    let balA = position.amountA;
    let balB = position.amountB;
    let feesA = 0n;
    let feesB = 0n;
    const points: ActualPoint[] = [{ t: p.start, share: wadToPct(valueShareA(usdValue(balA, position.priceA, decA), usdValue(balB, position.priceB, decB))), label: "shipped" }];
    for (const e of swaps) {
      const inIsA = e.tokenIn.toLowerCase() === p.tokenA.toLowerCase();
      if (inIsA) {
        balA += e.amountIn;
        balB -= e.amountOut;
        feesA += (e.amountIn * BigInt(p.feeBps)) / FEE_DENOMINATOR;
      } else {
        balB += e.amountIn;
        balA -= e.amountOut;
        feesB += (e.amountIn * BigInt(p.feeBps)) / FEE_DENOMINATOR;
      }
      points.push({ t: e.timestamp, share: wadToPct(valueShareA(usdValue(balA, position.priceA, decA), usdValue(balB, position.priceB, decB))) });
    }
    if (state.active) points.push({ t: s.now, share: wadToPct(shareNow), label: "now" });

    const feesUsd = usdValue(feesA, position.priceA, decA) + usdValue(feesB, position.priceB, decB);
    const progress = Math.min(1, Math.max(0, (s.now - p.start) / p.duration));
    return { wNow, shareNow, ref, spot, drift, points, feesA, feesB, feesUsd, progress, valueA, valueB };
  }, [v, s.now]);

  async function onDock() {
    if (!v.position) return;
    setBusy(true);
    setError(undefined);
    try {
      await dock(s.wallet, v.position.params);
      await s.refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  if (!v.position) {
    return (
      <div className="empty">
        No position yet. <Link href="/" style={{ color: "var(--accent)" }}>Create one</Link>, or ship with <span className="mono">contracts/scripts/demo.sh</span> and run <span className="mono">npm run sync</span>.
      </div>
    );
  }

  const { position, state, metaA, metaB, swaps } = v;
  const p = position.params;
  const isMaker = s.address.toLowerCase() === position.maker.toLowerCase();

  return (
    <>
      <div className="hero" style={{ display: "flex", alignItems: "flex-end", gap: 16 }}>
        <div>
          <h1>
            {metaA?.symbol ?? "A"} / {metaB?.symbol ?? "B"} glide{" "}
            {state && <span className={`badge ${state.active ? "live" : "off"}`}>{state.active ? "live" : "docked"}</span>}
          </h1>
          <p>
            maker <span className="mono">{short(position.maker)}</span> · {fmtPct(p.wA0)} → {fmtPct(p.wA1)} {metaA?.symbol} over {fmtDuration(p.duration)} · fee{" "}
            {(p.feeBps / 1e5).toFixed(2)}% · {v.hash && <span className="mono">{short(v.hash)}</span>}
          </p>
        </div>
        <div style={{ marginLeft: "auto" }} className="btn-row">
          {isMaker && state?.active && (
            <button className="btn danger" disabled={busy} onClick={onDock}>
              {busy ? "docking…" : "Dock position"}
            </button>
          )}
          <button
            className="btn ghost"
            onClick={() => {
              clearStoredPosition();
              v.setPosition(undefined);
            }}
          >
            Forget
          </button>
        </div>
      </div>

      {v.error && <div className="log err" style={{ marginBottom: 16 }}>{v.error}</div>}
      {error && <div className="log err" style={{ marginBottom: 16 }}>{error}</div>}

      {calc && state && metaA && metaB ? (
        <div className="grid" style={{ gridTemplateColumns: "1fr" }}>
          <div className="stats">
            <div className="stat">
              <div className="k">progress</div>
              <div className="v">{(calc.progress * 100).toFixed(0)}%</div>
              <div className="s">{s.now < p.start ? `starts ${fmtTime(p.start)}` : s.now >= p.start + p.duration ? "window complete" : `${fmtDuration(p.start + p.duration - s.now)} left`}</div>
            </div>
            <div className="stat">
              <div className="k">target {metaA.symbol} share</div>
              <div className="v">{wadToPct(calc.wNow).toFixed(1)}%</div>
              <div className="s">the curve&apos;s weight right now</div>
            </div>
            <div className="stat">
              <div className="k">actual {metaA.symbol} share</div>
              <div className={`v ${Math.abs(wadToPct(calc.shareNow) - wadToPct(calc.wNow)) < 2 ? "good" : "warn"}`}>{wadToPct(calc.shareNow).toFixed(1)}%</div>
              <div className="s">of ${fmtAmount(calc.valueA + calc.valueB, 18, 0)} exposed</div>
            </div>
            <div className="stat">
              <div className="k">pool price</div>
              <div className="v">{calc.spot.toPrecision(5)}</div>
              <div className="s">
                {metaB.symbol} per {metaA.symbol} · <span className={Math.abs(calc.drift) < 1 ? "good" : "warn"}>{calc.drift >= 0 ? "+" : ""}{calc.drift.toFixed(2)}% vs ref</span>
              </div>
            </div>
            <div className="stat">
              <div className="k">fees earned</div>
              <div className="v good">${fmtAmount(calc.feesUsd, 18, 2)}</div>
              <div className="s">
                {fmtAmount(calc.feesA, metaA.decimals)} {metaA.symbol} + {fmtAmount(calc.feesB, metaB.decimals)} {metaB.symbol}
              </div>
            </div>
            <div className="stat">
              <div className="k">trades</div>
              <div className="v">{swaps.length}</div>
              <div className="s">all settled from the maker&apos;s wallet</div>
            </div>
          </div>

          <div className="grid two">
            <div className="card">
              <h2>
                Path vs reality <span className="tag">line: target weight · dots: actual value share</span>
              </h2>
              <WeightChart params={p} now={s.now} actual={calc.points} symbolA={metaA.symbol} height={300} />
            </div>
            <div className="card">
              <h2>Balances</h2>
              <table>
                <thead>
                  <tr>
                    <th></th>
                    <th>exposed on Aqua</th>
                    <th>maker wallet</th>
                  </tr>
                </thead>
                <tbody>
                  <tr>
                    <td>{metaA.symbol}</td>
                    <td>{fmtAmount(state.balanceA, metaA.decimals)}</td>
                    <td>{fmtAmount(v.walletA, metaA.decimals)}</td>
                  </tr>
                  <tr>
                    <td>{metaB.symbol}</td>
                    <td>{fmtAmount(state.balanceB, metaB.decimals)}</td>
                    <td>{fmtAmount(v.walletB, metaB.decimals)}</td>
                  </tr>
                </tbody>
              </table>
              <p className="muted" style={{ marginTop: 12, fontSize: 12.5 }}>
                &quot;Exposed on Aqua&quot; is a virtual balance: the tokens stay in the maker&apos;s wallet and are pulled only when a trade executes. Wallet
                balances move by exactly the traded amounts, fee included.
              </p>
              <h2 style={{ marginTop: 18 }}>Reference</h2>
              <table>
                <tbody>
                  <tr>
                    <td className="muted">{metaA.symbol} price</td>
                    <td>${fmtAmount(position.priceA, 18, 2)}</td>
                  </tr>
                  <tr>
                    <td className="muted">{metaB.symbol} price</td>
                    <td>${fmtAmount(position.priceB, 18, 2)}</td>
                  </tr>
                  <tr>
                    <td className="muted">implied {metaB.symbol} per {metaA.symbol}</td>
                    <td>{calc.ref.toPrecision(5)}</td>
                  </tr>
                  <tr>
                    <td className="muted">window</td>
                    <td>
                      {fmtTime(p.start)} → {fmtTime(p.start + p.duration)}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <div className="card">
            <h2>
              Trades <span className="tag">router Swapped events for this order</span>
            </h2>
            {swaps.length === 0 ? (
              <div className="empty">no trades yet: use the demo tools to arb the position or swap through Uniswap</div>
            ) : (
              <table>
                <thead>
                  <tr>
                    <th>time</th>
                    <th>taker</th>
                    <th>paid</th>
                    <th>received</th>
                    <th>maker fee</th>
                    <th>tx</th>
                  </tr>
                </thead>
                <tbody>
                  {[...swaps].reverse().map((e) => {
                    const inIsA = e.tokenIn.toLowerCase() === p.tokenA.toLowerCase();
                    const mIn = inIsA ? metaA : metaB;
                    const mOut = inIsA ? metaB : metaA;
                    const fee = (e.amountIn * BigInt(p.feeBps)) / FEE_DENOMINATOR;
                    return (
                      <tr key={e.txHash}>
                        <td className="muted">{fmtTime(e.timestamp)}</td>
                        <td className="mono">{short(e.taker)}</td>
                        <td>
                          {fmtAmount(e.amountIn, mIn.decimals)} {mIn.symbol}
                        </td>
                        <td>
                          {fmtAmount(e.amountOut, mOut.decimals)} {mOut.symbol}
                        </td>
                        <td className="good">
                          {fmtAmount(fee, mIn.decimals, 6)} {mIn.symbol}
                        </td>
                        <td className="mono muted">{short(e.txHash)}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            )}
          </div>
        </div>
      ) : (
        <div className="empty">{s.ready ? "reading position…" : "waiting for RPC…"}</div>
      )}
    </>
  );
}
