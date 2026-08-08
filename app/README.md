# Clearwave

Compliance-gated music royalty shares on Monad. Independent artists sell a share of
future streaming royalties to CVI-verified investors.

Built for the Cleanverse **Build: Trusted Assets** hackathon, RWA track.

## What makes it different

Compliance is not a check this app performs. It is a property of the asset.

The royalty share **is** a Cleanverse A-Token, so the token contract itself refuses to
mint to or transfer between wallets without an A-Pass. Removing this frontend, or
calling the contracts directly, does not get you around it. The `RoyaltyDistributor`
goes further: it holds its own A-Pass and cannot move a single unit of royalty without
one.

## Stack

Next.js (App Router) · wagmi + viem · Tailwind v4 · Monad testnet (10143)

Contracts live in a separate repo (`monad-contracts`): `ShareOffering`,
`RoyaltyDistributor`, `APassComplianceValidator`.

## Running it

```bash
npm install
cp env.sample .env.local     # optional; defaults work for read-only
npm run dev
```

The landing page renders **live on-chain state without a wallet connected**. That is
deliberate — see below.

## The demo constraint

Judges do not hold A-Passes. A demo that opens with "connect your wallet and buy" would
refuse every one of them and read as broken software.

So the page leads with two pre-provisioned wallets — one verified, one not — and shows a
live `canBuyAmount()` read for each. Same call the buy transaction makes. The refusal is
the demo, not an obstacle to it.

Private keys for those wallets are in `~/.clearwave/wallets.json`, outside this repo.

## Security

`CLEANVERSE_API_KEY` is an AES key that decrypts every Cleanverse API response. It must
never be prefixed `NEXT_PUBLIC_`, never be imported into a client component, and only
ever be read inside a route handler. Cleanverse calls belong on the server, without
exception.

Cloudflare fronts the Cleanverse API and returns `403 error code: 1010` to Python's
default User-Agent *before* checking auth. Set a browser-style UA on outbound calls or
you will misdiagnose it as a credentials problem.

## Not done yet

Buy flow, claim flow, and the live `generate_apass` verification route are intentionally
unbuilt — that is the Aug 8-9 work.
