import "server-only";

import { createWalletClient, http, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

import { chain } from "./contracts";

/**
 * Server-only signers for the two demo wallets.
 *
 * These keys sign real transactions on Monad testnet from throwaway demo wallets that
 * hold nothing but testnet CWUSD. They are read from the server environment and must
 * never be prefixed NEXT_PUBLIC_ — that would ship them in the client bundle. The
 * `server-only` import above turns any accidental client import into a build error
 * rather than a leak discovered later.
 *
 * The unverified wallet is deliberately funded and approved exactly like the verified
 * one. If it failed for want of CWUSD the demo would prove nothing about compliance —
 * see `classifyFailure`, which refuses to call a balance error a compliance refusal.
 */
export type DemoWalletKey = "verified" | "unverified";

const ENV_VAR: Record<DemoWalletKey, string> = {
  verified: "DEMO_VERIFIED_PRIVATE_KEY",
  unverified: "DEMO_UNVERIFIED_PRIVATE_KEY",
};

export function isDemoWalletKey(v: unknown): v is DemoWalletKey {
  return v === "verified" || v === "unverified";
}

/** True when both demo signers are configured; the UI hides the buy panel otherwise. */
export function demoSigningAvailable(): boolean {
  return Object.values(ENV_VAR).every((name) => Boolean(process.env[name]));
}

export function getDemoAccount(which: DemoWalletKey) {
  const raw = process.env[ENV_VAR[which]];
  if (!raw) {
    throw new Error(`${ENV_VAR[which]} is not set`);
  }
  const key = (raw.startsWith("0x") ? raw : `0x${raw}`) as Hex;
  return privateKeyToAccount(key);
}

export function getDemoWalletClient(which: DemoWalletKey) {
  return createWalletClient({
    account: getDemoAccount(which),
    chain,
    transport: http(process.env.MONAD_TESTNET_RPC ?? undefined),
  });
}
