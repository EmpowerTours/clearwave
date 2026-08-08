/**
 * Public addresses only. The private keys live in `~/.clearwave/wallets.json`, outside this
 * repo, and must stay there — see .gitignore.
 *
 * These exist because of a constraint that shapes the whole demo: judges do not hold
 * A-Passes, so "connect your wallet and buy" would refuse every one of them and read as a
 * broken app. Showing both a verified and an unverified wallet side by side turns the
 * compliance wall from the thing that blocks the demo into the thing the demo is about.
 */
export const DEMO_WALLETS = [
  {
    key: "verified",
    label: "Verified investor",
    address: "0x9843F23B7B451dD72e9475789033E2948738D9Bb",
    note: "Holds a Cleanverse A-Pass. Can buy, can claim royalties.",
  },
  {
    key: "unverified",
    label: "Unverified investor",
    address: "0x24c6eCa9Cac2B110698223ac19691c76e357319D",
    note: "No A-Pass. The A-Token itself refuses the transfer on-chain.",
  },
] as const satisfies ReadonlyArray<{
  key: string;
  label: string;
  address: `0x${string}`;
  note: string;
}>;

export const ARTIST_ADDRESS =
  "0x08ee06BaFb8cFE3bC8B3eD1D19A2CebE6284CC09" as const;
