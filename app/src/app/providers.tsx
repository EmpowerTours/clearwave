"use client";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState } from "react";
// Import `injected` from @wagmi/core, NOT from "wagmi/connectors". That barrel re-exports
// baseAccount -> @coinbase/cdp-sdk -> @x402/evm, an optional peer that is not installed, and
// the webpack build fails on it. @wagmi/core is where `injected` actually lives.
import { injected } from "@wagmi/core";
import { createConfig, http, WagmiProvider } from "wagmi";

import { chain } from "@/lib/contracts";

/**
 * Injected-only for now. RainbowKit is installed but deliberately not wired yet: its
 * getDefaultConfig wants a WalletConnect projectId, and a scaffold that hard-depends on a
 * third-party service fails in exactly the situation we cannot afford it to — a judge
 * opening the demo. MetaMask on Monad testnet is the path that has to work.
 */
const config = createConfig({
  chains: [chain],
  connectors: [injected()],
  transports: { [chain.id]: http() },
  ssr: true,
});

export function Providers({ children }: { children: React.ReactNode }) {
  const [queryClient] = useState(() => new QueryClient());

  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    </WagmiProvider>
  );
}
