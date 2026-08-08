import { NextResponse } from "next/server";
import { BaseError, ContractFunctionRevertedError } from "viem";

import { ABIS, CONTRACTS, explorerUrl } from "@/lib/contracts";
import {
  demoSigningAvailable,
  getVerifiedAccount,
  getVerifiedWalletClient,
  isDemoWalletKey,
  type DemoWalletKey,
} from "@/lib/demoSigner";
import { DEMO_WALLETS } from "@/lib/demoWallets";
import { publicClient } from "@/lib/publicClient";

export const dynamic = "force-dynamic";

/**
 * Cap on a single demo purchase. The demo wallets hold a finite amount of testnet
 * CWUSD and this endpoint is unauthenticated by design — anyone loading the page can
 * fire it. A cap means the worst case is a drained demo offering, not a drained wallet
 * mid-judging.
 */
const MAX_SHARES = 5n;

type Outcome =
  | { status: "bought"; txHash: string; explorer: string; shares: string }
  | { status: "refused"; reason: string; detail: string; compliance: boolean }
  | { status: "error"; reason: string };

/**
 * Turn a revert into an honest label.
 *
 * The entire point of this demo is that the unverified wallet is stopped BY COMPLIANCE.
 * If it were stopped by an empty balance we would be filming a funding bug and calling
 * it a compliance control. `compliance: false` marks any refusal we cannot attribute to
 * the gate, so the UI can say so plainly instead of taking credit for it.
 */
function classifyFailure(
  errorName: string | undefined,
  message: string,
): {
  reason: string;
  detail: string;
  compliance: boolean;
} {
  switch (errorName) {
    case "BuyerNotCompliant":
      return {
        reason: "Refused by compliance",
        detail:
          "ShareOffering.buy() reverted with BuyerNotCompliant — the validator returned false for this wallet.",
        compliance: true,
      };
    case "NoAPass":
      return {
        reason: "Refused by compliance",
        detail:
          "The A-Token itself reverted with NoAPass. The share token refuses to be transferred to a wallet without an A-Pass, independently of our contracts.",
        compliance: true,
      };
    case "AttributeChecksUnavailable":
      return {
        reason: "Refused by compliance",
        detail:
          "This offering requires attribute checks and no attribute oracle is set, so the validator refuses rather than admitting on an unenforced gate.",
        compliance: true,
      };
    case "PoolPaused":
      return {
        reason: "Refused by compliance",
        detail: "The pool is paused in the validator.",
        compliance: true,
      };
    case "ERC20InsufficientBalance":
    case "PaymentNotReceived":
      return {
        reason: "Failed on funding, not compliance",
        detail:
          "This wallet ran out of testnet CWUSD. That is a demo funding problem — it is NOT the compliance gate, and should not be presented as one.",
        compliance: false,
      };
    case "SoldOut":
    case "OfferingIsClosed":
    case "OfferingExpired":
      return {
        reason: "Offering unavailable",
        detail: `The offering itself rejected the purchase (${errorName}).`,
        compliance: false,
      };
    default:
      return {
        reason: errorName ? `Reverted: ${errorName}` : "Reverted",
        detail: message.slice(0, 300),
        compliance: false,
      };
  }
}

function extractRevert(err: unknown): { errorName?: string; message: string } {
  const message = err instanceof Error ? err.message : String(err);
  if (err instanceof BaseError) {
    const reverted = err.walk(
      (e) => e instanceof ContractFunctionRevertedError,
    );
    if (reverted instanceof ContractFunctionRevertedError) {
      return { errorName: reverted.data?.errorName, message };
    }
  }
  return { message };
}

export async function POST(req: Request) {
  if (!demoSigningAvailable()) {
    return NextResponse.json<Outcome>(
      {
        status: "error",
        reason:
          "Demo signing is not configured on this deployment (DEMO_*_PRIVATE_KEY unset).",
      },
      { status: 503 },
    );
  }

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return NextResponse.json<Outcome>(
      { status: "error", reason: "Malformed request body." },
      { status: 400 },
    );
  }

  const { wallet, offeringId, shares } = (body ?? {}) as {
    wallet?: unknown;
    offeringId?: unknown;
    shares?: unknown;
  };

  if (!isDemoWalletKey(wallet)) {
    return NextResponse.json<Outcome>(
      { status: "error", reason: "wallet must be 'verified' or 'unverified'." },
      { status: 400 },
    );
  }
  if (
    typeof offeringId !== "number" ||
    !Number.isInteger(offeringId) ||
    offeringId < 0
  ) {
    return NextResponse.json<Outcome>(
      { status: "error", reason: "offeringId must be a non-negative integer." },
      { status: 400 },
    );
  }

  const requested = BigInt(typeof shares === "number" ? shares : 1);
  if (requested <= 0n || requested > MAX_SHARES) {
    return NextResponse.json<Outcome>(
      {
        status: "error",
        reason: `shares must be between 1 and ${MAX_SHARES}.`,
      },
      { status: 400 },
    );
  }

  const which = wallet as DemoWalletKey;

  /**
   * The unverified wallet is simulated from its public address and never signs. It has
   * no key on this server, and needs none: `buy()` evaluates compliance before payment,
   * so its simulation always reverts and there is nothing to broadcast.
   */
  const account =
    which === "verified"
      ? getVerifiedAccount()
      : (DEMO_WALLETS.find((w) => w.key === "unverified")!
          .address as `0x${string}`);

  try {
    // Simulate first. A refusal is an expected outcome here, not an exception —
    // simulating means we surface the exact custom error without spending gas on a
    // transaction we already know reverts.
    const { request } = await publicClient.simulateContract({
      address: CONTRACTS.shareOffering,
      abi: ABIS.shareOffering,
      functionName: "buy",
      args: [BigInt(offeringId), requested],
      account,
    });

    const hash = await getVerifiedWalletClient().writeContract(request);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });

    if (receipt.status !== "success") {
      return NextResponse.json<Outcome>({
        status: "refused",
        reason: "Transaction reverted on-chain",
        detail: `Simulation passed but the transaction reverted in block ${receipt.blockNumber}.`,
        compliance: false,
      });
    }

    return NextResponse.json<Outcome>({
      status: "bought",
      txHash: hash,
      explorer: explorerUrl("tx", hash),
      shares: requested.toString(),
    });
  } catch (err) {
    const { errorName, message } = extractRevert(err);
    return NextResponse.json<Outcome>({
      status: "refused",
      ...classifyFailure(errorName, message),
    });
  }
}
