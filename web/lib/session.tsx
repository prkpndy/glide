"use client";

import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { demoAccounts, demoWallet, publicClient, rpc, type Role } from "./clients";
import { chainNow } from "./glide";
import { CHAIN_ID, deployment } from "./config";

type Session = {
  role: Role;
  setRole: (r: Role) => void;
  address: `0x${string}`;
  wallet: ReturnType<typeof demoWallet>;
  now: number; // chain time, seconds
  block: bigint;
  tick: number; // increments on every refresh, subscribe to re-read chain state
  refresh: () => Promise<void>;
  connect: () => Promise<void>;
  connecting: boolean;
  error?: string;
  ready: boolean;
};

const Ctx = createContext<Session | null>(null);

export function SessionProvider({ children }: { children: ReactNode }) {
  const [role, setRole] = useState<Role>("maker");
  const [now, setNow] = useState(0);
  const [block, setBlock] = useState(0n);
  const [tick, setTick] = useState(0);
  const [ready, setReady] = useState(false);
  const [enabled, setEnabled] = useState(false);
  const [connecting, setConnecting] = useState(false);
  const [error, setError] = useState<string>();

  const refresh = useCallback(async () => {
    try {
      const t = await chainNow();
      setNow(t.timestamp);
      setBlock(t.block);
      setReady(true);
      setError(undefined);
    } catch {
      setReady(false);
      setEnabled(false);
      setError("Cannot reach Anvil. Start the local fork and allow this site's local network access, then reconnect.");
    }
    setTick((x) => x + 1);
  }, []);

  const connect = useCallback(async () => {
    setConnecting(true);
    setError(undefined);
    try {
      if (!deployment) throw new Error("This frontend has no deployment snapshot. Run setup.sh and npm run sync, then rebuild it.");
      const [version, chainId] = await Promise.all([rpc<string>("web3_clientVersion"), publicClient.getChainId()]);
      if (!version.toLowerCase().includes("anvil")) throw new Error("Start an Anvil fork at the configured local RPC.");
      if (chainId !== CHAIN_ID) throw new Error(`Start Anvil with --chain-id ${CHAIN_ID}.`);
      const codes = await Promise.all([deployment.router, deployment.lens, deployment.hook, deployment.swapRouter].map(address => publicClient.getCode({ address })));
      if (codes.some(code => !code || code === "0x")) throw new Error("Local contracts do not match this app. Run setup.sh from the same version of the repository on a fresh fork.");
      setEnabled(true);
      await refresh();
    } catch (e) {
      setReady(false);
      setEnabled(false);
      setError(e instanceof Error && !e.message.includes("\n") ? e.message : "Cannot reach Anvil. Start the fork and allow this site's local network access, then reconnect.");
    } finally {
      setConnecting(false);
    }
  }, [refresh]);

  useEffect(() => {
    // Hosted pages wait for an explicit click before requesting local network access.
    // Local development starts its browser-only connection after hydration.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    if (["localhost", "127.0.0.1", "[::1]"].includes(window.location.hostname)) void connect();
  }, [connect]);

  useEffect(() => {
    if (!enabled) return;
    const id = setInterval(refresh, 3000);
    return () => clearInterval(id);
  }, [refresh, enabled]);

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
      connect,
      connecting,
      error,
      ready: ready && !!deployment,
    }),
    [role, now, block, tick, refresh, connect, connecting, error, ready],
  );

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useSession() {
  const s = useContext(Ctx);
  if (!s) throw new Error("useSession outside SessionProvider");
  return s;
}
