import { formatUnits } from "viem";

import { ConnectedWallet } from "@/components/ConnectedWallet";
import { Addr, Badge, Panel, Row } from "@/components/ui";
import { CONTRACTS, PAYMENT_DECIMALS, chain } from "@/lib/contracts";
import { DEMO_WALLETS } from "@/lib/demoWallets";
import { canBuy, getOffering, getOfferingCount } from "@/lib/reads";

/** On-chain state moves; don't serve a stale page to a judge mid-demo. */
export const revalidate = 10;

function cwusd(v: bigint): string {
  return `${formatUnits(v, PAYMENT_DECIMALS)} CWUSD`;
}

export default async function Page() {
  const count = await getOfferingCount();

  if (count === 0) {
    return (
      <main className="mx-auto max-w-3xl p-6">
        <p className="text-[var(--muted)]">No offerings yet.</p>
      </main>
    );
  }

  // Newest offering is the live demo. Enumerate properly once there is more than one.
  const id = count - 1;
  const offering = await getOffering(id);

  const compliance = await Promise.all(
    DEMO_WALLETS.map(async (w) => ({
      ...w,
      allowed: await canBuy(id, w.address, 1n),
    })),
  );

  return (
    <main className="mx-auto flex max-w-3xl flex-col gap-5 p-6">
      <header className="flex items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold">Clearwave</h1>
          <p className="mt-1 text-sm text-[var(--muted)]">
            Compliance-gated music royalty shares. Artists sell a slice of
            future streaming royalties to verified investors.
          </p>
        </div>
        <span className="shrink-0 rounded-full border border-[var(--border)] px-3 py-1 text-xs text-[var(--muted)]">
          {chain.name} · {chain.id}
        </span>
      </header>

      <Panel
        title={`Offering #${offering.id}`}
        subtitle="A Cleanverse A-Token representing a share of this artist's royalties."
      >
        <Row label="Status">
          <Badge ok={offering.inactiveReason === ""}>
            {offering.inactiveReason === "" ? "Open" : offering.inactiveReason}
          </Badge>
        </Row>
        <Row label="Share token">
          <Addr value={offering.shareToken} />
        </Row>
        <Row label="Artist">
          <Addr value={offering.artist} />
        </Row>
        <Row label="Price per share">{cwusd(offering.pricePerShare)}</Row>
        <Row label="Sold">
          {offering.sharesSold.toString()} / {offering.totalShares.toString()}
        </Row>
        <Row label="Remaining">{offering.sharesRemaining.toString()}</Row>
        <Row label="Supply invariant">
          <Badge ok={offering.supplyIntact}>
            {offering.supplyIntact ? "intact" : "VIOLATED"}
          </Badge>
        </Row>
      </Panel>

      <Panel
        title="Compliance is enforced on-chain"
        subtitle="These are live canBuyAmount() reads against the deployed contract — not a UI mock. The same check the buy transaction runs."
      >
        <div className="flex flex-col gap-3">
          {compliance.map((w) => (
            <div
              key={w.key}
              className="flex items-start justify-between gap-4 rounded-lg border border-[var(--border)] p-3"
            >
              <div>
                <div className="text-sm font-medium">{w.label}</div>
                <div className="mt-0.5 text-xs text-[var(--muted)]">
                  {w.note}
                </div>
                <div className="mt-1.5">
                  <Addr value={w.address} />
                </div>
              </div>
              <Badge ok={w.allowed}>{w.allowed ? "can buy" : "refused"}</Badge>
            </div>
          ))}
        </div>
      </Panel>

      <ConnectedWallet offeringId={id} />

      <Panel
        title="Under the hood"
        subtitle="Every contract below is ours except the A-Tokens, which Cleanverse issues and which enforce compliance themselves."
      >
        <Row label="ShareOffering">
          <Addr value={CONTRACTS.shareOffering} />
        </Row>
        <Row label="RoyaltyDistributor">
          <Addr value={CONTRACTS.royaltyDistributor} />
        </Row>
        <Row label="APassComplianceValidator">
          <Addr value={CONTRACTS.validator} />
        </Row>
        <Row label="CWUSD (settlement A-Token)">
          <Addr value={CONTRACTS.payment} />
        </Row>
        <p className="mt-4 text-xs leading-relaxed text-[var(--muted)]">
          The RoyaltyDistributor holds its own Cleanverse A-Pass. It is not a
          wrapper around compliance — it is itself a verified entity, and
          without that A-Pass it cannot receive or pay out a single unit of
          royalty.
        </p>
      </Panel>
    </main>
  );
}
