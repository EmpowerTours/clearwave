# Clearwave

Tokenized royalty share offerings with on-chain compliance gating, built on Monad
and integrated with Cleanverse CVI/CVA.

## What it does

Rights holders raise capital against future royalties by issuing shares in an
offering. Investors buy in only if they clear compliance. Royalties that arrive
later are distributed pro-rata to shareholders on-chain.

Compliance is not a checkbox in a database — `APassComplianceValidator` gates
participation at the contract level, so an ineligible wallet cannot buy in even
by calling the contract directly.

## Contracts (Monad testnet)

| contract | address |
|---|---|
| ShareOffering | `0xD9ebD0BB7FCdbF171E855C34b58ed1A74B043a87` |
| RoyaltyDistributor | `0x26b32987cb5d7946D81e0Cc7459f26CdeC773101` |
| APassComplianceValidator | `0x45bDfe4A464dbF90D8915A2AeaCdc92C696256eB` |
| Payment token | `0x1A3225eb4d5Eb81FcffD9cf5b554CfA3D02BaD40` |

## Repo layout

```
contracts/          Foundry project
  src/              ShareOffering, RoyaltyDistributor, APassComplianceValidator
  test/             Foundry tests incl. supply invariant and audit rounds
  script/           DeployClearwave, SetupOffering
app/                Next.js frontend (viem + wagmi)
  src/lib/          contract bindings, ABIs, read helpers, demo wallets
```

## Building

Foundry dependencies are git submodules pinned to exact commits (forge-std
`0768d9c`, openzeppelin-contracts `fd81a96`), so a recursive clone reproduces the
build exactly:

```bash
git clone --recursive https://github.com/EmpowerTours/clearwave.git
cd clearwave/contracts
forge build
forge test
```

If you already cloned without `--recursive`:

```bash
git submodule update --init --recursive
```

Frontend:

```bash
cd app
npm install
npm run dev
```

Set `MONAD_TESTNET_RPC` to override the default RPC endpoint.

## Tests

```bash
cd contracts && forge test -vv
```

Includes a supply invariant test for `ShareOffering` and two audit-round test
suites covering `RoyaltyDistributor` and offering edge cases.
