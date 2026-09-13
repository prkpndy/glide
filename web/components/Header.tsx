"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useSession } from "@/lib/session";
import { fmtTime, short } from "@/lib/format";
import { RPC_URL } from "@/lib/config";

const links = [
  { href: "/", label: "Create" },
  { href: "/position", label: "Position" },
  { href: "/demo", label: "Demo tools" },
] as const;

export default function Header() {
  const path = usePathname();
  const s = useSession();
  return (
    <header className="header">
      <div className="brand">
        <span className="logo">◐</span>
        <div>
          <div className="brand-name">Glide</div>
          <div className="brand-sub">self-custodial glide-path liquidity on 1inch Aqua</div>
        </div>
      </div>
      <nav className="nav">
        {links.map((l) => (
          <Link key={l.href} href={l.href} className={path === l.href ? "active" : ""}>
            {l.label}
          </Link>
        ))}
      </nav>
      <div className="session">
        <div className="role">
          <button className={s.role === "maker" ? "on" : ""} onClick={() => s.setRole("maker")}>
            maker
          </button>
          <button className={s.role === "taker" ? "on" : ""} onClick={() => s.setRole("taker")}>
            taker
          </button>
          <span className="mono">{short(s.address)}</span>
        </div>
        <div className="chain">
          {s.ready ? (
            <>
              <span className="dot ok" /> block {s.block.toString()} · {fmtTime(s.now)}
            </>
          ) : (
            <>
              <button className="btn ghost small" disabled={s.connecting} onClick={s.connect}>
                {s.connecting ? "Connecting…" : "Connect local fork"}
              </button>
            </>
          )}
        </div>
        <div className="chain">Your computer · {RPC_URL}</div>
        {s.error && <div className="warn" role="alert" style={{ maxWidth: 380, fontSize: 12 }}>{s.error}</div>}
      </div>
    </header>
  );
}
