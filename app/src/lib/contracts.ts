import { monadTestnet } from "viem/chains";

import ShareOfferingAbi from "./abis/ShareOffering.json";
import RoyaltyDistributorAbi from "./abis/RoyaltyDistributor.json";
import APassComplianceValidatorAbi from "./abis/APassComplianceValidator.json";

export const chain = monadTestnet; // id 10143

/**
 * Post-audit build, deployed 2026-07-29. Verified live from this repo on the same date:
 * offeringCount() = 1, roundCount() = 1, and ShareOffering.payment()/validator() point at
 * the CWUSD and validator addresses below. Do not swap these for the superseded pre-audit
 * deployments, and do not point at Monad mainnet (143) — the mainnet A-Pass registry is
 * empty, so every compliance check there fails closed.
 */
export const CONTRACTS = {
  shareOffering: "0xD9ebD0BB7FCdbF171E855C34b58ed1A74B043a87",
  royaltyDistributor: "0x26b32987cb5d7946D81e0Cc7459f26CdeC773101",
  validator: "0x45bDfe4A464dbF90D8915A2AeaCdc92C696256eB",
  /** CWUSD — settlement currency, a real Cleanverse A-Token. 6 decimals. */
  payment: "0x1A3225eb4d5Eb81FcffD9cf5b554CfA3D02BaD40",
} as const satisfies Record<string, `0x${string}`>;

export const ABIS = {
  shareOffering: ShareOfferingAbi,
  royaltyDistributor: RoyaltyDistributorAbi,
  validator: APassComplianceValidatorAbi,
} as const;

/** Minimal ERC-20 surface. A-Tokens expose no burn, no snapshot and no transfer hook. */
export const ERC20_ABI = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "allowance",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "value", type: "uint256" },
    ],
    outputs: [{ type: "bool" }],
  },
  {
    type: "function",
    name: "decimals",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint8" }],
  },
  {
    type: "function",
    name: "symbol",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "string" }],
  },
] as const;

/**
 * A-Tokens enforce compliance themselves and gate the SENDER as well as the recipient.
 * These two selectors are how we tell a compliance refusal apart from an ordinary
 * insufficient-balance failure, which matters because the UI claims a specific reason.
 */
export const REVERT_SELECTORS = {
  /** NoAPass(address) — thrown by the A-Token when either party lacks an A-Pass. */
  noAPass: "0xa6725971",
  /** ERC20InsufficientBalance(...) — an ordinary balance failure, NOT a compliance one. */
  insufficientBalance: "0xe450d38c",
  /** AlreadyClaimed(...) — RoyaltyDistributor double-claim. */
  alreadyClaimed: "0x6bd4745f",
} as const;

export const PAYMENT_DECIMALS = 6;

export function explorerUrl(kind: "address" | "tx", value: string): string {
  const base =
    chain.blockExplorers?.default.url ?? "https://testnet.monadexplorer.com";
  return `${base}/${kind}/${value}`;
}
