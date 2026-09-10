"use client";

import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { demoAccounts, demoWallet, type Role } from "./clients";
import { chainNow } from "./glide";
import { deployment } from "./config";

type Session = {
  role: Role;
  setRole: (r: Role) => void;
  address: `0x${string}`;
  wallet: ReturnType<typeof demoWallet>;
  now: number; // chain time, seconds
  block: bigint;
  tick: number; // increments on every refresh, subscribe to re-read chain state
  refresh: () => Promise<void>;
  ready: boolean;
};

const Ctx = createContext<Session | null>(null);

export function SessionProvider({ children }: { children: ReactNode }) {
  const [role, setRole] = useState<Role>("maker");
  const [now, setNow] = useState(0);
  const [block, setBlock] = useState(0n);
  const [tick, setTick] = useState(0);
  const [ready, setReady] = useState(false);

  const refresh = useCallback(async () => {
    try {
      const t = await chainNow();
      setNow(t.timestamp);
      setBlock(t.block);
      setReady(true);
    } catch {
      setReady(false);
    }
    setTick((x) => x + 1);
  }, []);

  useEffect(() => {
    refresh();
    const id = setInterval(refresh, 3000);
    return () => clearInterval(id);
  }, [refresh]);

  const value = useMemo<Session>(
    () => ({
      role,
      setRole,
      address: demoAccounts[role].address,
      wallet: demoWallet(role),
      now,
      block,
      tick,
      refresh,
      ready: ready && !!deployment,
    }),
    [role, now, block, tick, refresh, ready],
  );

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useSession() {
  const s = useContext(Ctx);
  if (!s) throw new Error("useSession outside SessionProvider");
  return s;
}
