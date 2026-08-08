import { ABIS, CONTRACTS } from "./contracts";
import { publicClient } from "./publicClient";

export type Offering = {
  id: number;
  artist: `0x${string}`;
  shareToken: `0x${string}`;
  pricePerShare: bigint;
  totalShares: bigint;
  sharesSold: bigint;
  closesAt: bigint;
  closed: boolean;
  isSealed: boolean;
  requireAttributeChecks: boolean;
  baselineSupply: bigint;
  /** Empty string when the offering is buyable. */
  inactiveReason: string;
  sharesRemaining: bigint;
  supplyIntact: boolean;
};

const offering = {
  address: CONTRACTS.shareOffering,
  abi: ABIS.shareOffering,
} as const;

/**
 * Every component of the returned struct is named in the ABI, so viem decodes it into an
 * OBJECT — not a positional array. Indexing it gave undefined on every field and the
 * build died on `.toString()`. Verified against the deployed contract.
 */
type RawOffering = {
  artist: `0x${string}`;
  shareToken: `0x${string}`;
  pricePerShare: bigint;
  totalShares: bigint;
  sharesSold: bigint;
  closesAt: bigint;
  closed: boolean;
  isSealed: boolean;
  requireAttributeChecks: boolean;
  baselineSupply: bigint;
};

export async function getOfferingCount(): Promise<number> {
  const n = (await publicClient.readContract({
    ...offering,
    functionName: "offeringCount",
  })) as bigint;
  return Number(n);
}

export async function getOffering(id: number): Promise<Offering> {
  const [raw, inactiveReason, sharesRemaining, supplyIntact] =
    await Promise.all([
      publicClient.readContract({
        ...offering,
        functionName: "getOffering",
        args: [BigInt(id)],
      }) as Promise<RawOffering>,
      publicClient.readContract({
        ...offering,
        functionName: "inactiveReason",
        args: [BigInt(id)],
      }) as Promise<string>,
      publicClient.readContract({
        ...offering,
        functionName: "sharesRemaining",
        args: [BigInt(id)],
      }) as Promise<bigint>,
      publicClient.readContract({
        ...offering,
        functionName: "supplyIntact",
        args: [BigInt(id)],
      }) as Promise<boolean>,
    ]);

  return {
    id,
    ...raw,
    inactiveReason,
    sharesRemaining,
    supplyIntact,
  };
}

/**
 * The whole product thesis in one call. Mirrors every precondition `buy` enforces,
 * including the buyer's A-Pass — so a `false` here is the same refusal the chain would
 * give, not a UI guess. A divergence between this and `buy` was a real bug once; treat
 * any mismatch as a defect in the contract, not something to paper over in the frontend.
 */
export async function canBuy(
  id: number,
  buyer: `0x${string}`,
  wholeShares: bigint,
): Promise<boolean> {
  return (await publicClient.readContract({
    ...offering,
    functionName: "canBuyAmount",
    args: [BigInt(id), buyer, wholeShares],
  })) as boolean;
}

export async function costFor(
  id: number,
  wholeShares: bigint,
): Promise<bigint> {
  return (await publicClient.readContract({
    ...offering,
    functionName: "costFor",
    args: [BigInt(id), wholeShares],
  })) as bigint;
}
