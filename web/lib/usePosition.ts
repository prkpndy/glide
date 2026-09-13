"use client";

import { useEffect, useState } from "react";
import type { Address, Hex } from "viem";
import { deployment, loadPosition, savePosition, type Position } from "./config";
import { balanceOf, orderHash, readState, swapsFor, tokenMeta, type PositionState, type SwapEvent, type TokenMeta } from "./glide";
import { useSession } from "./session";

export type PositionView = {
  position: Position | undefined;
  hash: Hex | undefined;
  state: PositionState | undefined;
  swaps: SwapEvent[];
  metaA: TokenMeta | undefined;
  metaB: TokenMeta | undefined;
  walletA: bigint;
  walletB: bigint;
  error: string | undefined;
  setPosition: (p: Position | undefined) => void;
};

export function usePosition(): PositionView {
  const s = useSession();
  const [position, setPositionState] = useState<Position | undefined>(undefined);
  const [hash, setHash] = useState<Hex>();
  const [state, setState] = useState<PositionState>();
  const [swaps, setSwaps] = useState<SwapEvent[]>([]);
  const [metaA, setMetaA] = useState<TokenMeta>();
  const [metaB, setMetaB] = useState<TokenMeta>();
  const [walletA, setWalletA] = useState(0n);
  const [walletB, setWalletB] = useState(0n);
  const [error, setError] = useState<string>();

  useEffect(() => {
    // Hydrate browser storage after server rendering.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setPositionState(loadPosition());
  }, []);

  useEffect(() => {
    if (!deployment || !s.ready) return;
    tokenMeta(deployment.tokenA).then(setMetaA).catch(() => {});
    tokenMeta(deployment.tokenB).then(setMetaB).catch(() => {});
  }, [s.ready]);

  useEffect(() => {
    if (!position || !s.ready) return;
    let cancelled = false;
    (async () => {
      try {
        const h = await orderHash(position.maker, position.params);
        const [st, ev, a, b] = await Promise.all([
          readState(position.maker, position.params),
          swapsFor(h),
          balanceOf(position.params.tokenA, position.maker as Address),
          balanceOf(position.params.tokenB, position.maker as Address),
        ]);
        if (cancelled) return;
        setHash(h);
        setState(st);
        setSwaps(ev);
        setWalletA(a);
        setWalletB(b);
        setError(undefined);
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [position, s.tick, s.ready]);

  const setPosition = (p: Position | undefined) => {
    if (p) savePosition(p);
    setPositionState(p);
  };

  return { position, hash, state, swaps, metaA, metaB, walletA, walletB, error, setPosition };
}
