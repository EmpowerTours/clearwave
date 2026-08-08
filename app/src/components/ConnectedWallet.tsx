"use client";

import { formatUnits } from "viem";
import { useAccount, useConnect, useDisconnect, useReadContract } from "wagmi";

import {
  ABIS,
  CONTRACTS,
  ERC20_ABI,
  PAYMENT_DECIMALS,
  chain,
} from "@/lib/contracts";

import { Addr, Badge, Panel, Row } from "./ui";

export function ConnectedWallet({ offeringId }: { offeringId: number }) {
  const { address, isConnected, chainId } = useAccount();
  const { connect, connectors, isPending } = useConnect();
  const { disconnect } = useDisconnect();

  const wrongChain = isConnected && chainId !== chain.id;

  const { data: allowed } = useReadContract({
    address: CONTRACTS.shareOffering,
    abi: ABIS.shareOffering,
    functionName: "canBuyAmount",
    args: address ? [BigInt(offeringId), address, 1n] : undefined,
    query: { enabled: Boolean(address) && !wrongChain },
  });

  const { data: balance } = useReadContract({
    address: CONTRACTS.payment,
    abi: ERC20_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: Boolean(address) && !wrongChain },
  });

  if (!isConnected) {
    const injectedConnector = connectors[0];
    return (
      <Panel
        title="Your wallet"
        subtitle="Optional. The offering above is real on-chain state and renders without one."
      >
        <button
          type="button"
          disabled={!injectedConnector || isPending}
          onClick={() =>
            injectedConnector && connect({ connector: injectedConnector })
          }
          className="rounded-lg border border-[var(--border)] px-4 py-2 text-sm font-medium hover:bg-white/5 disabled:opacity-50"
        >
          {isPending ? "Connecting…" : "Connect wallet"}
        </button>
        <p className="mt-3 text-xs text-[var(--muted)]">
          Expect to be refused: a wallet without a Cleanverse A-Pass cannot buy.
          That refusal is the point, and it comes from the token contract, not
          from this page.
        </p>
      </Panel>
    );
  }

  return (
    <Panel title="Your wallet">
      <Row label="Address">{address ? <Addr value={address} /> : "—"}</Row>
      {wrongChain ? (
        <p className="py-3 text-sm text-[var(--danger)]">
          Wrong network. Switch to {chain.name} (chain {chain.id}) to read your
          compliance status.
        </p>
      ) : (
        <>
          <Row label="CWUSD balance">
            {balance === undefined
              ? "…"
              : `${formatUnits(balance as bigint, PAYMENT_DECIMALS)} CWUSD`}
          </Row>
          <Row label="Can buy shares">
            {allowed === undefined ? (
              "…"
            ) : (
              <Badge ok={Boolean(allowed)}>
                {allowed ? "yes — A-Pass verified" : "no — not verified"}
              </Badge>
            )}
          </Row>
        </>
      )}
      <button
        type="button"
        onClick={() => disconnect()}
        className="mt-4 text-xs text-[var(--muted)] underline underline-offset-4 hover:text-[var(--text)]"
      >
        Disconnect
      </button>
    </Panel>
  );
}
