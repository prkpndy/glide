"use client";

import { useEffect, useState } from "react";
import { parseUnits } from "viem";
import { WAD } from "@/lib/config";
import { advanceTime, quote, readState, spotBPerA, swapDirect, swapViaUniswap } from "@/lib/glide";
import { fmtAmount, fmtDuration } from "@/lib/format";
import { useSession } from "@/lib/session";
import { usePosition } from "@/lib/usePosition";

type Line = { text: string; kind?: "ok" | "err" };

export default function DemoPage() {
  const s = useSession();
  const v = usePosition();
  const [aToB, setAToB] = useState(true);
  const [amount, setAmount] = useState("300");
  const [via, setVia] = useState<"direct" | "uniswap">("uniswap");
  const [quoted, setQuoted] = useState<bigint>();
  const [busy, setBusy] = useState(false);
  const [log, setLog] = useState<Line[]>([]);

  const add = (text: string, kind?: Line["kind"]) => setLog((l) => [...l.slice(-60), { text, kind }]);

  const metaIn = aToB ? v.metaA : v.metaB;
  const metaOut = aToB ? v.metaB : v.metaA;

  useEffect(() => {
    if (!v.position || !metaIn || !s.ready) return;
    let cancelled = false;
    (async () => {
      try {
        const amt = parseUnits(amount || "0", metaIn.decimals);
        if (amt === 0n) return setQuoted(undefined);
        const q = await quote(v.position!.maker, v.position!.params, true, aToB, amt);
        if (!cancelled) setQuoted(q.amountOut);
      } catch {
        if (!cancelled) setQuoted(undefined);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [v.position, metaIn, amount, aToB, s.tick, s.ready]);

  async function onAdvance(seconds: number) {
    setBusy(true);
    try {
      await advanceTime(seconds);
      add(`advanced chain time by ${fmtDuration(seconds)}`, "ok");
      await s.refresh();
    } catch (e) {
      add(String(e), "err");
    } finally {
      setBusy(false);
    }
  }

  async function onSwap() {
    if (!v.position || !metaIn || !metaOut) return;
    setBusy(true);
    try {
      const amt = parseUnits(amount || "0", metaIn.decimals);
      const q = await quote(v.position.maker, v.position.params, true, aToB, amt);
      const minOut = (q.amountOut * 995n) / 1000n;
      add(`${via === "uniswap" ? "Uniswap v4" : "router"}: ${fmtAmount(amt, metaIn.decimals)} ${metaIn.symbol} → quoted ${fmtAmount(q.amountOut, metaOut.decimals)} ${metaOut.symbol}`);
      const hash =
        via === "uniswap"
          ? await swapViaUniswap(s.wallet, aToB, amt, minOut)
          : await swapDirect(s.wallet, v.position.maker, v.position.params, aToB, amt, minOut);
      add(`filled from the maker's wallet · tx ${hash.slice(0, 10)}…`, "ok");
      await s.refresh();
    } catch (e) {
      add(e instanceof Error ? e.message.split("\n")[0] : String(e), "err");
    } finally {
      setBusy(false);
    }
  }

  async function onArb() {
    if (!v.position || !v.metaA || !v.metaB) return;
    setBusy(true);
    const { maker, params, priceA, priceB } = v.position;
    const decA = v.metaA.decimals;
    const decB = v.metaB.decimals;
    // reference B per A in the same raw-unit WAD that spotBPerA uses
    const ref = (priceA * 10n ** BigInt(decB) * WAD) / (priceB * 10n ** BigInt(decA));
    add(`arbing towards reference price (${(Number(priceA) / Number(priceB)).toPrecision(5)} ${v.metaB.symbol} per ${v.metaA.symbol})`);
    try {
      for (let i = 0; i < 40; i++) {
        const st = await readState(maker, params);
        if (!st.active) throw new Error("position is docked");
        const spot = spotBPerA(st.balanceA, st.wA, st.balanceB);
        const driftBps = Number(((spot - ref) * 10000n) / ref);
        if (Math.abs(driftBps) <= 50) {
          add(`within ${Math.abs(driftBps)} bps of reference after ${i} trade(s)`, "ok");
          break;
        }
        // pool overvalues A (gives too much B per A) -> sell A to the maker; otherwise sell B.
        // Trade size scales with the gap: 1% of the reserve when close, up to 20% when far off (the curve caps at 30%).
        const sellA = spot > ref;
        const reserve = sellA ? st.balanceA : st.balanceB;
        const fracBps = BigInt(Math.min(2000, Math.max(100, Math.round(Math.abs(driftBps) / 4))));
        const size = (reserve * fracBps) / 10000n;
        const q = await quote(maker, params, true, sellA, size);
        const mIn = sellA ? v.metaA : v.metaB;
        const mOut = sellA ? v.metaB : v.metaA;
        await swapDirect(s.wallet, maker, params, sellA, size, (q.amountOut * 99n) / 100n);
        add(`  ${driftBps > 0 ? "+" : ""}${driftBps} bps → sold ${fmtAmount(size, mIn.decimals)} ${mIn.symbol} for ${fmtAmount(q.amountOut, mOut.decimals)} ${mOut.symbol}`);
      }
      await s.refresh();
    } catch (e) {
      add(e instanceof Error ? e.message.split("\n")[0] : String(e), "err");
    } finally {
      setBusy(false);
    }
  }

  if (!v.position) return <div className="empty">No position to trade against yet.</div>;

  return (
    <>
      <div className="hero">
        <h1>Demo tools</h1>
        <p>
          Everything a taker or an arbitrageur would do, plus fork time travel. Trades here are real transactions on the local fork and settle from the
          maker&apos;s wallet through Aqua.
        </p>
      </div>

      <div className="grid three">
        <div className="card">
          <h2>Time travel</h2>
          <p className="muted" style={{ marginBottom: 12 }}>
            The glide reads <span className="mono">block.timestamp</span>. Jump ahead to watch the target weight move.
          </p>
          <div className="btn-row">
            {[3600, 6 * 3600, 12 * 3600, 24 * 3600].map((sec) => (
              <button key={sec} className="btn ghost" disabled={busy} onClick={() => onAdvance(sec)}>
                +{fmtDuration(sec)}
              </button>
            ))}
          </div>
        </div>

        <div className="card">
          <h2>Arbitrage to reference</h2>
          <p className="muted" style={{ marginBottom: 12 }}>
            Repeatedly trades in whichever direction pushes the pool price back to the reference price, sizing each trade by the gap, which is what an
            arbitrage bot does. Each trade pays the maker&apos;s fee.
          </p>
          <button className="btn" disabled={busy || s.role !== "taker"} onClick={onArb}>
            {busy ? "working…" : "Arb until within 50 bps"}
          </button>
          {s.role !== "taker" && <p className="warn" style={{ marginTop: 8, fontSize: 12 }}>switch to the taker account</p>}
        </div>

        <div className="card">
          <h2>Swap</h2>
          <div className="field">
            <label>
              <span>direction</span>
            </label>
            <select value={aToB ? "ab" : "ba"} onChange={(e) => setAToB(e.target.value === "ab")}>
              <option value="ab">
                {v.metaA?.symbol} → {v.metaB?.symbol}
              </option>
              <option value="ba">
                {v.metaB?.symbol} → {v.metaA?.symbol}
              </option>
            </select>
          </div>
          <div className="field">
            <label>
              <span>amount in ({metaIn?.symbol})</span>
              <span className="mono">{quoted !== undefined && metaOut ? `≈ ${fmtAmount(quoted, metaOut.decimals, 6)} ${metaOut.symbol}` : "no quote"}</span>
            </label>
            <input type="text" value={amount} onChange={(e) => setAmount(e.target.value)} />
          </div>
          <div className="field">
            <label>
              <span>route</span>
            </label>
            <select value={via} onChange={(e) => setVia(e.target.value as "direct" | "uniswap")}>
              <option value="uniswap">Uniswap v4 pool → GlideHook → router → Aqua</option>
              <option value="direct">Glide router → Aqua</option>
            </select>
          </div>
          <button className="btn" disabled={busy || quoted === undefined || s.role !== "taker"} onClick={onSwap}>
            {busy ? "working…" : "Swap"}
          </button>
        </div>
      </div>

      <div className="card" style={{ marginTop: 20 }}>
        <h2>Log</h2>
        <div className="log">
          {log.length === 0 ? "nothing yet" : log.map((l, i) => (
            <div key={i} className={l.kind}>
              {l.text}
            </div>
          ))}
        </div>
      </div>
    </>
  );
}
