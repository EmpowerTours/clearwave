"use client";

import { useState } from "react";

import { Panel } from "./ui";

type Outcome =
  | { status: "bought"; txHash: string; explorer: string; shares: string }
  | { status: "refused"; reason: string; detail: string; compliance: boolean }
  | { status: "error"; reason: string };

type WalletKey = "verified" | "unverified";

const WALLETS: ReadonlyArray<{
  key: WalletKey;
  label: string;
  expectation: string;
}> = [
  {
    key: "verified",
    label: "Buy as verified investor",
    expectation: "Holds an A-Pass — expect this to settle.",
  },
  {
    key: "unverified",
    label: "Buy as unverified investor",
    expectation: "No A-Pass — expect the contract to refuse.",
  },
];

export function DemoBuy({ offeringId }: { offeringId: number }) {
  const [pending, setPending] = useState<WalletKey | null>(null);
  const [results, setResults] = useState<Partial<Record<WalletKey, Outcome>>>(
    {},
  );

  async function run(wallet: WalletKey) {
    setPending(wallet);
    setResults((r) => ({ ...r, [wallet]: undefined }));
    try {
      const res = await fetch("/api/demo-buy", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ wallet, offeringId, shares: 1 }),
      });
      const outcome = (await res.json()) as Outcome;
      setResults((r) => ({ ...r, [wallet]: outcome }));
    } catch (e) {
      setResults((r) => ({
        ...r,
        [wallet]: {
          status: "error",
          reason: e instanceof Error ? e.message : "Request failed",
        },
      }));
    } finally {
      setPending(null);
    }
  }

  return (
    <Panel
      title="Buy one share — as either wallet"
      subtitle="Both buttons send a real transaction on Monad testnet, signed server-side by the demo wallets. Same code path, same offering; only the A-Pass differs."
    >
      <div className="flex flex-col gap-4">
        {WALLETS.map((w) => {
          const out = results[w.key];
          return (
            <div
              key={w.key}
              className="rounded-lg border border-[var(--border)] p-3"
            >
              <div className="flex items-center justify-between gap-4">
                <div>
                  <div className="text-sm font-medium">{w.label}</div>
                  <div className="mt-0.5 text-xs text-[var(--muted)]">
                    {w.expectation}
                  </div>
                </div>
                <button
                  type="button"
                  disabled={pending !== null}
                  onClick={() => run(w.key)}
                  className="shrink-0 rounded-lg border border-[var(--border)] px-4 py-2 text-sm font-medium hover:bg-white/5 disabled:opacity-50"
                >
                  {pending === w.key ? "Sending…" : "Buy 1 share"}
                </button>
              </div>

              {out && (
                <div className="mt-3 border-t border-[var(--border)] pt-3 text-xs">
                  {out.status === "bought" && (
                    <>
                      <div className="font-medium text-[var(--ok)]">
                        Settled — {out.shares} share
                      </div>
                      <a
                        href={out.explorer}
                        target="_blank"
                        rel="noreferrer"
                        className="mt-1 inline-block break-all underline underline-offset-4 text-[var(--muted)] hover:text-[var(--text)]"
                      >
                        {out.txHash}
                      </a>
                    </>
                  )}

                  {out.status === "refused" && (
                    <>
                      <div
                        className={
                          out.compliance
                            ? "font-medium text-[var(--ok)]"
                            : "font-medium text-[var(--danger)]"
                        }
                      >
                        {out.reason}
                      </div>
                      <p className="mt-1 leading-relaxed text-[var(--muted)]">
                        {out.detail}
                      </p>
                      {!out.compliance && (
                        <p className="mt-1 leading-relaxed text-[var(--danger)]">
                          This is not the compliance gate. Do not present it as
                          one.
                        </p>
                      )}
                    </>
                  )}

                  {out.status === "error" && (
                    <div className="text-[var(--danger)]">{out.reason}</div>
                  )}
                </div>
              )}
            </div>
          );
        })}
      </div>

      <p className="mt-4 text-xs leading-relaxed text-[var(--muted)]">
        The refusal is produced by the chain, not by this page. The button is
        enabled either way — nothing is hidden client-side — and the transaction
        is simulated against the deployed contract before it is sent, so the
        error shown is the contract&apos;s own.
      </p>
    </Panel>
  );
}
