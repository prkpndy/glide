"use client";

import { CartesianGrid, ComposedChart, Line, ReferenceLine, ResponsiveContainer, Scatter, Tooltip, XAxis, YAxis } from "recharts";
import type { GlideParams } from "@/lib/config";
import { weightAt } from "@/lib/glide";
import { wadToPct } from "@/lib/format";

export type ActualPoint = { t: number; share: number; label?: string };

export default function WeightChart({
  params,
  now,
  actual = [],
  symbolA,
  height = 260,
}: {
  params: GlideParams;
  now?: number;
  actual?: ActualPoint[];
  symbolA: string;
  height?: number;
}) {
  const start = params.start;
  const end = params.start + params.duration;
  const pad = params.duration * 0.1;
  const from = Math.min(start - pad, ...(actual.length ? actual.map((a) => a.t) : [start - pad]), now ?? start);
  const to = Math.max(end + pad, ...(actual.length ? actual.map((a) => a.t) : [end + pad]), now ?? end);
  const h = (t: number) => (t - start) / 3600;

  const target = [] as { h: number; target: number }[];
  const steps = 60;
  for (let i = 0; i <= steps; i++) {
    const t = from + ((to - from) * i) / steps;
    target.push({ h: h(t), target: wadToPct(weightAt(params, t)) });
  }
  const points = actual.map((a) => ({ h: h(a.t), actual: a.share, label: a.label }));

  return (
    <div style={{ width: "100%", height }}>
      <ResponsiveContainer>
        <ComposedChart margin={{ top: 12, right: 16, bottom: 8, left: 0 }}>
          <CartesianGrid stroke="var(--grid)" strokeDasharray="3 3" />
          <XAxis
            dataKey="h"
            type="number"
            domain={[h(from), h(to)]}
            tickFormatter={(v: number) => `${v >= 0 ? "+" : ""}${v.toFixed(0)}h`}
            stroke="var(--muted)"
            fontSize={12}
          />
          <YAxis domain={[0, 100]} tickFormatter={(v: number) => `${v}%`} stroke="var(--muted)" fontSize={12} width={44} />
          <Tooltip
            contentStyle={{ background: "var(--panel)", border: "1px solid var(--border)", borderRadius: 8, fontSize: 12 }}
            formatter={(v, name) => [`${Number(v ?? 0).toFixed(2)}%`, name === "target" ? `target ${symbolA} weight` : `actual ${symbolA} value share`]}
            labelFormatter={(v) => `${Number(v ?? 0).toFixed(1)}h from start`}
          />
          <ReferenceLine x={0} stroke="var(--muted)" strokeDasharray="2 4" label={{ value: "start", fill: "var(--muted)", fontSize: 11, position: "insideTopLeft" }} />
          <ReferenceLine x={h(end)} stroke="var(--muted)" strokeDasharray="2 4" label={{ value: "end", fill: "var(--muted)", fontSize: 11, position: "insideTopRight" }} />
          {now !== undefined && <ReferenceLine x={h(now)} stroke="var(--accent)" label={{ value: "now", fill: "var(--accent)", fontSize: 11, position: "top" }} />}
          <Line data={target} dataKey="target" type="linear" stroke="var(--accent)" strokeWidth={2} dot={false} isAnimationActive={false} name="target" />
          <Scatter data={points} dataKey="actual" fill="var(--good)" isAnimationActive={false} name="actual" />
        </ComposedChart>
      </ResponsiveContainer>
    </div>
  );
}
