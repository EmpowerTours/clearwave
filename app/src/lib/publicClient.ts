import { createPublicClient, http } from "viem";

import { chain } from "./contracts";

/**
 * Read-only client used by server components so the landing page renders real on-chain
 * state before any wallet is connected. Judges see live data on first paint; the wallet
 * only matters once they try to act.
 */
export const publicClient = createPublicClient({
  chain,
  transport: http(
    process.env.MONAD_TESTNET_RPC ?? chain.rpcUrls.default.http[0],
  ),
});
