import { createPublicClient, createWalletClient, defineChain, http, type Account } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { CHAIN_ID, DEMO_MAKER_PK, DEMO_TAKER_PK, RPC_URL } from "./config";

export const chain = defineChain({
  id: CHAIN_ID,
  name: CHAIN_ID === 130 ? "Unichain (local fork)" : `Chain ${CHAIN_ID}`,
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
});

export const publicClient = createPublicClient({ chain, transport: http(RPC_URL) });

export type Role = "maker" | "taker";

export const demoAccounts: Record<Role, Account> = {
  maker: privateKeyToAccount(DEMO_MAKER_PK),
  taker: privateKeyToAccount(DEMO_TAKER_PK),
};

export function demoWallet(role: Role) {
  return createWalletClient({ account: demoAccounts[role], chain, transport: http(RPC_URL) });
}

export type Wallet = ReturnType<typeof demoWallet>;

/** Raw JSON-RPC, used for anvil's time-travel methods. */
export async function rpc<T = unknown>(method: string, params: unknown[] = []): Promise<T> {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return (publicClient.request as any)({ method, params }) as Promise<T>;
}
