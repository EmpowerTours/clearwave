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

const VERIFIED_KEY_VAR = "DEMO_VERIFIED_PRIVATE_KEY";

export function isDemoWalletKey(v: unknown): v is DemoWalletKey {
  return v === "verified" || v === "unverified";
}

/** True when the verified signer is configured; the UI hides the buy panel otherwise. */
export function demoSigningAvailable(): boolean {
  return Boolean(process.env[VERIFIED_KEY_VAR]);
}

/**
 * Only the verified wallet ever signs.
 *
 * `buy()` evaluates compliance before it touches payment, so the unverified wallet
 * always reverts during simulation and no transaction is ever broadcast from it. It
 * therefore needs an address, not a key — and its address is already public in
 * demoWallets.ts. Keeping its key out of the deployment removes a live private key
 * from the server environment for no loss of demo fidelity.
 */
export function getVerifiedAccount() {
  const raw = process.env[VERIFIED_KEY_VAR];
  if (!raw) {
    throw new Error(`${VERIFIED_KEY_VAR} is not set`);
  }
  const key = (raw.startsWith("0x") ? raw : `0x${raw}`) as Hex;
  return privateKeyToAccount(key);
}

export function getVerifiedWalletClient() {
  return createWalletClient({
    account: getVerifiedAccount(),
    chain,
    transport: http(process.env.MONAD_TESTNET_RPC ?? undefined),
  });
}
