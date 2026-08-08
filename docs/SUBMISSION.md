# Clearwave — One-Page Summary

**Tokenized royalty share offerings with compliance enforced at the contract level, on Monad.**

---

## Problem

A rights holder with predictable royalty income cannot easily raise against it. The
instruments that exist are private, slow, and gated by intermediaries. Tokenizing the
cash flow is the obvious fix and has been tried repeatedly — it fails on compliance.

Every existing attempt puts eligibility checks in the application layer: a database
flag, a KYC vendor callback, a disabled button. That is not a control. Anyone can call
the contract directly and bypass it entirely. If the gate is not in the contract, there
is no gate — which is exactly why institutions will not touch these instruments.

## Solution

Three contracts on Monad:

- **`ShareOffering`** — a rights holder issues shares in future royalties. Investors
  buy in with a payment token. Supply is invariant-tested.
- **`RoyaltyDistributor`** — royalties arriving later are distributed pro-rata to
  shareholders on-chain, with dust handling covered by dedicated tests.
- **`APassComplianceValidator`** — eligibility is evaluated *inside* `buy()`. An
  ineligible wallet cannot participate even by calling the contract directly with no
  frontend involved.

The compliance check is the product. The offering mechanics are conventional on
purpose; the contribution is making the gate unavoidable.

## CVI · CVA integration points

**We read A-Pass directly on Monad, because the gateway does not serve it there.**
Cleanverse's cooperate API exposes `/validator/*` for registering pools, setting rules,
and verifying wallets. Empirically those endpoints answer only for `base` — `monad`
returns error 12027, the same code returned for a chain slug that does not exist. The
A-Pass registry itself, however, *is* deployed on Monad and is a standard ERC-721
(`name() = "A-Pass"`, `symbol() = "APASS"`, `supportsInterface(0x80ac58cd) = true`), so
a contract can read compliance state on-chain with no gateway in the path.

**We validated the on-chain read against the gateway's own answer.** Across every
sampled registered wallet, `balanceOf(w) == 1` coincided with `verify_apass` returning
code 4 ("valid A-Pass, transfer allowed"), and `balanceOf(w) == 0` coincided with
code 2. The on-chain gate reproduces the gateway's verdict rather than approximating it.

**We mirror the gateway's API shape exactly.** `register` / `setRule` / `addRule` /
`removeRule` / `setPaused` / `verify` / `rules` / `isRegistered` / `isPaused`. A pool
configured on Monad is configured the same way it would be on Base — including
Cleanverse's documented `minTier` semantics, which are *strictly greater than*, not
`>=`. `minTier = 30` admits tier 31 and rejects tier 30. Preserved deliberately to
avoid an off-by-one against the reference implementation.

**We do not fake what Cleanverse does not expose.** The rule struct implements tier,
subTier, and country allow/deny lists in full. But the A-Pass implementation on Monad
publishes no getter for those attributes, so inventing a source of truth would mean
claiming a check we cannot perform. Instead `verify()` returns `(ok, checked)` —
`checked` is false whenever only A-Pass possession was verified. `attributeOracle` is
the single seam to plug in real attribute reads the day Cleanverse publishes the A-Pass
ABI, with no redeploy. Offerings that genuinely require jurisdiction rules can set
`requireAttributeChecks` and will refuse to proceed rather than admit wallets on an
unenforced gate.

**Compliance fails closed.** The A-Pass registry is an ERC-1967 proxy whose
implementation Cleanverse controls. An unguarded call meant a reverting or
gas-burning registry would take down `verify()`, every `buy()`, and every frontend
across all pools simultaneously. Calls are gas-capped at 150k and failure is treated as
an answer — unreachable registry means not verified.

## Deployed — Monad testnet

| contract | address |
|---|---|
| ShareOffering | `0xD9ebD0BB7FCdbF171E855C34b58ed1A74B043a87` |
| RoyaltyDistributor | `0x26b32987cb5d7946D81e0Cc7459f26CdeC773101` |
| APassComplianceValidator | `0x45bDfe4A464dbF90D8915A2AeaCdc92C696256eB` |
| Payment token | `0x1A3225eb4d5Eb81FcffD9cf5b554CfA3D02BaD40` |

The frontend performs live `canBuyAmount()` reads against these deployed contracts for
each demo wallet — the same check the buy transaction runs, not a UI mock.

## Build quality

134 tests pass across seven suites, including a `ShareOffering` supply invariant, dust
handling in `RoyaltyDistributor`, `canBuy` parity between the view helper and the
transaction path, and three rounds of audit-fix tests.

Adversarial review drove concrete changes. Rule and country lists are hard-capped
(`MAX_RULES = 16`, `MAX_COUNTRIES = 32`) because `verify()` loops both and is called
from `buy()` — measured at 16.5k gas for one rule versus 124k for sixty, so an
unbounded owner could have pushed `buy()` past the block gas limit and bricked a live
offering. The caps are constants rather than owner-settable precisely because the owner
is the party they constrain. `renounceOwnership` is disabled: pool registration gates
every new offering, so an ownerless validator would permanently freeze the platform via
a single unconfirmed call.

An empty rule set returning `checked = true` — an open gate certifying itself as
enforced — was found independently by all five audit passes and is now explicitly
handled.

## Scalability

Every loop in the compliance path is bounded by constants, so `buy()` gas is capped
regardless of owner configuration. External calls to both the registry and the oracle
are gas-limited and failure-tolerant, so no single dependency can halt trading platform-wide.
The validator is repointable to a different A-Pass registry without redeploy or
migration, which is how it ships to mainnet the day Cleanverse issues mainnet A-Passes.
