# ERC-8415 Native Infrastructure Kit (NIK)

Open components, APIs and runnable examples for **ERC-8415: Asynchronous Register Projection for NFTs**.

ERC-8415 lets a token follow an asset whose ownership is decided by an external register, such as a warehouse register, custody ledger or securities register. The Kit is the infrastructure an application needs to use it: it records the register's confirmed-holder history, tracks changes that are still in progress, verifies the proofs that admit new entries, and answers the questions a wallet, marketplace, lender or AI agent must ask before it acts.

**Standard status (2026-10-04): Draft.** The [upstream proposal, ethereum/ERCs#2006](https://github.com/ethereum/ERCs/pull/2006), is open and has not been merged. This repository is an implementation toolkit; its tests are not a certification of full conformance or production readiness. The [proposal text at the reviewed revision](https://github.com/ethereum/ERCs/blob/12e68aee54c6f94f6910d4db42f1d5677b506de1/ERCS/erc-8415.md) defines the semantics; the [standard's repository](https://github.com/GiraffeJP/ERC-8415) contains the draft, interfaces and reference material.

## What problem the Kit solves

A token can change hands in seconds. The register that legally decides who owns the underlying asset may take hours or days to record the same change, and sometimes rejects it. An application that treats `ownerOf` as the owner will pay the wrong party, release escrow too early, or accept collateral that is not yet the borrower's.

The Kit keeps the two apart and makes the register's view usable:

- **Who the register recognised at a given time**, with `holderAsOf(tokenId, t)`.
- **Whether that answer is settled**, with `isFinalAsOf(tokenId, t)`.
- **Whether a change is in flight right now**, with `openGapOf(tokenId)`.

Each is readable on chain, so an application can check all three inside the transaction that depends on them.

## Where the Kit fits in a trade

The example below is illustrative and implies no relationship with any exchange, warehouse operator or registry. Trader A sells a warehouse receipt for 25 tonnes of copper to fund B on a trading platform. The platform and the parties set the commercial rules; the Kit supplies the register-facing infrastructure.

| Step | What happens | Kit component | Outside the Kit |
| --- | --- | --- | --- |
| 1. List | The receipt's first register entry, naming A, is admitted with a bound proof | `ProjectionSettlement.initializeRegister`, `RegisterProjection` | Listing and order book |
| 2. Order and pay | B, or an agent acting for B, orders; payment goes into escrow | None | Wallet, escrow, payment rails |
| 3. Contract forms | The token moves to B; `ownerOf` changes, the projection does not | ERC-721 transfer is independent of the projection | Platform's trading rules |
| 4. Registration requested | A gap opens: a change is in progress | `beginSettlement`, `openGapOf`, `openedAt` | Custodian files the change with the register |
| 5. Registered | The register's new entry naming B is admitted; the gap closes | `finalizeSettlement` with a verified proof | Escrow reads `holderAsOf` in the release transaction and pays A |
| 6. Rejected or timed out | The gap is cancelled after its deadline; history is unchanged | `cancelSettlement` | Escrow refunds B; the asset stays where it was |

If B resells to C before the register records B, trading continues and the projection keeps naming the last confirmed holder until each change is admitted in order.

## Quick start

Requirements: **Node.js 22.18 or newer**, npm, and Python 3 for the Python SDK checks. CI runs on Node 22 and 24. Hardhat downloads Solidity 0.8.28 on first use, so that run needs access to the compiler host.

```sh
git clone https://github.com/GiraffeJP/ERC8415-Kit.git
cd ERC8415-Kit
npm ci
npm run verify
```

`verify` runs TypeScript checks, the Node suite with an 80% line, branch and function coverage gate, and the local-EVM contract suite. No wallet, external RPC endpoint, testnet funds or private key is needed.

To run only the record-date consumer example after installing dependencies:

```sh
npm run test:onchain -- tests/onchain/recordDateClaim.onchain.cjs
```

The four tests deploy the components to Hardhat's in-process EVM and exercise real local transactions. They are the quickest way to see the read-then-act pattern below.

## Example: a record-date payment

[`RecordDateClaim.sol`](contracts/examples/RecordDateClaim.sol) is a minimal, non-normative CC0 consumer for a dividend-style record-date payment. Each deployment is funded for one token, one record date and one native-currency payout. The caller must be the recorded holder at that date, and the claim can succeed only once.

Within the claim transaction, it checks:

1. `isFinalAsOf(tokenId, recordDate)` is true.
2. `holderAsOf(tokenId, recordDate)` is the caller.
3. `openGapOf(tokenId)` is zero. This extra refusal policy belongs to the example; an open gap does not make a historical instant non-final.

It records the claim before the external payout call. This is an integration example, not a complete dividend distribution or escrow system.

The [executable walkthrough](tests/onchain/recordDateClaim.onchain.cjs) uses effective times `1000`, `1500` and `2000`:

- An initial entry names Alice at `1000`; the record date `1500` is covered but provisional.
- A confirming entry naming Alice again, effective at `2000`, makes `1500` final. Alice can claim once while no gap is open; Bob cannot.
- A later entry naming Bob does not change Alice's already-final record-date answer.
- An entry effective exactly at `1500` does **not** make `1500` final.
- If a gap opens earlier in the same block as the claim, the claim sees it and refuses, even though historical finality remains true.

The register's `effectiveAt`, the application's record date and the block in which an entry is admitted are different times. The example resolves the record date against admitted effective-time history, not against the admission timestamp or the current ERC-721 owner.

## Core semantics

ERC-8415 keeps two sequences distinct:

- **Tradeable position:** `ownerOf` changes with ERC-721 transfers.
- **Confirmed holder:** `holderAsOf(tokenId, t)` reads the holder reported by the external register for effective time `t`, as recorded in the projection.

The Kit never substitutes `ownerOf` for a historical holder. Record agreement does not establish legal title or prove that both records refer to the same underlying right.

For a token with admitted entries, the temporal finality rule is:

```text
isFinalAsOf(tokenId, t) == true
iff firstEntry.effectiveAt <= t < latestEntry.effectiveAt
```

A later entry may confirm the same holder. The latest interval remains provisional until an entry effective strictly after the queried instant is admitted. Before the first entry, `holderAsOf` and `entryAsOf` revert; `isFinalAsOf` returns false.

Keep these signals separate:

- **Final or provisional:** derived from admitted effective-time history.
- **Open or closed gap:** whether a settlement change is in flight; `openedAt` locates its start.
- **Freshness or reorg safety:** optional information with separate trust and timing assumptions.

Proof verification, gap closure, cancellation, timeout expiry and block confirmation depth do not themselves establish historical finality. Cancellation leaves admitted history unchanged. A registrar that stops issuing entries can leave recent instants provisional indefinitely.

### Read and act in one transaction

For an action that depends on projection state, read and validate the required conditions **inside the same transaction as that action**. Earlier RPC or HTTP reads are fine for display but may be stale when a transaction executes. Two separate transactions in the same block do not close this window.

Applications choose whether to wait for finality, decline while a gap is open or accept a provisional answer. Escrow, refunds, timeouts and downstream unwinding remain application policies. Neither opening a gap nor cancelling one freezes or reverses ERC-721 transfers.

## What is implemented

### Projection and admission

- Append-only entry history with consecutive versions, strictly increasing `effectiveAt`, commitment linkage and per-token commitment uniqueness.
- `registerId`, `holderAsOf`, `entryAsOf`, `isFinalAsOf`, `currentEntry`, `entryAt` and `entryCount`.
- A TypeScript admission pipeline with proof binding, replay protection and remote-height checks.
- TypeScript Merkle and Ed25519 attestation profiles, plus a **mock zk profile** for testing.
- Solidity projection and optional settlement components, with a pluggable `ISettlementProofVerifier` and an example EIP-191/secp256k1 attestation verifier. This on-chain verifier is distinct from the TypeScript Ed25519 profile.

### API and operational components

- An authenticated [HTTP API](api/README.md) with temporal reads and an admission endpoint.
- [JavaScript and Python SDKs](sdk/README.md) for read-only API consumption. They do not submit on-chain transactions. `resolve` returns holder, finality and gap from one server snapshot; it does not guarantee the state of a later transaction.
- A read-only [console](console/README.md), API-key/RBAC and tenant-isolation primitives, metrics and audit export.
- An [append-only file journal and replay support](engine/persistence/README.md).
- An [Ethereum adapter](adapters/README.md) that reads a configured application's SHA-256 admission-tree root at a canonical finalised block. It trusts the configured RPC, does not independently verify Ethereum state proofs and must be refreshed by its caller.
- Shared [semantic vectors](conformance/projection-vectors.json), Node tests and local-EVM tests.

The repository is source-distributed (`private: true` in `package.json`); the quick start uses a checkout rather than a published npm package.

## Contract assembly and compatibility

The draft defines two discoverable surfaces:

```text
IRegisterProjection       0x6309e170
IProjectionSettlement     0xdfdd14e8
```

`IProjectionSettlement` now declares `verifier()`, which moved its identifier
from the previously recorded `0xf4a7d71b`. `verificationProfile()` names the
profile but not the code deciding an admission; `verifier()` names that code.
In `ProjectionSettlement` the address is immutable, so a consumer can inspect
it on chain once. A deployment that puts an upgradeable verifier there must
expose that verifier's upgrade authority, since the profile identifier does not
move when the code behind it does.

One optional interface sits beside the pair, and answering it does not affect
either identifier above:

```text
IRegistryReferencePolicy  0x42ae525a
```

A register advertising it and answering `canonicalRegistryReference() == true`
guarantees every entry carries a nonzero `registryReference`. Canonical form
beyond "nonzero" is profile-defined and the interface does not specify it.

An instrument discovers the policy from the settlement contract it already
holds: call `projection()` on it to get the register address, call
`supportsInterface(0x42ae525a)` on that address, and read
`canonicalRegistryReference()` only if it answers true. `projection()` is this
component's accessor, not part of either frozen interface, so a deployment that
composes the surfaces differently has to expose the register address its own
way. The property belongs to the register, so the settlement contract does not
advertise it on its own behalf. A register that does not advertise the interface gives no guarantee at
all, which is the same position as one that advertises it and answers false:
the instrument must treat every `registryReference` as possibly zero and index
accordingly.

This does not move the one-reference-per-live-asset rule onto the register.
Collateral and escrow contracts still maintain their own index of one registry
reference per live asset; the flag only tells them whether the reference they
are indexing is meaningful, rather than a zero that would silently collapse
every such asset onto one key.

The Kit supplies separate components:

- [`RegisterProjection`](contracts/RegisterProjection.sol) stores and queries history and advertises the projection interface. Its writes are authority-gated; it does not verify proofs itself.
- [`ProjectionSettlement`](contracts/ProjectionSettlement.sol) advertises the settlement interface and holds the projection's source authority in the tested assembly. It verifies a bound proof before initialisation or admission, opens gaps and closes them by admission or cancellation. Settlement authority is separate from token ownership.
- [`RecordDateClaim`](contracts/examples/RecordDateClaim.sol) receives the projection and settlement addresses separately. Its [test setup](tests/onchain/recordDateClaim.onchain.cjs) shows the wiring and verifier configuration.

These contracts do not provide an ERC-721 implementation or a single-address ERC-721, projection and settlement composition. The draft's settlement-conformance level includes projection conformance; advertising an interface on one component does not establish conformance of the whole deployed asset. Integrators must check the composed address surfaces, token-existence behaviour, authority and proof profile against the draft before claiming conformance.

Known differences from the [reviewed draft](https://github.com/ethereum/ERCs/blob/12e68aee54c6f94f6910d4db42f1d5677b506de1/ERCS/erc-8415.md):

- The example on-chain verifier checks an attestor signature over the admission binding. The Solidity path has no consumed remote-height tracking and does not independently verify remote membership or finality. It does not implement the draft's complete settlement-proof requirements; the TypeScript pipeline's checks do not supply those checks on chain.
- The component rejects a second open gap with `GapAlreadyOpen`. The draft permits a profile to forbid supersession where its register cannot absorb it; an integration must make that policy explicit.
- `settlement(unknownId)` returns the zero-value `NONE` record, whereas the draft requires a revert.

The test suite is evidence for the behaviour it exercises, not an exhaustive draft-conformance check.

## Trust and production boundaries

The Kit provides projection, admission and query infrastructure. Applications decide the user experience, settlement policy and downstream actions. It is not a wallet, marketplace, registry operator, legal title authority or financial product.

- Accepted proof evidence does not prove the truth or legal validity of the underlying register. Consumers must accept the configured source authority, verifier and profile assumptions.
- Commitment uniqueness is per token. Cross-token uniqueness of commitments or registry references, and continuity across tokens, are registrar or application responsibilities. Escrow and financing instruments that assume one registry reference per live asset must enforce it themselves.
- The chain carries commitments and reference locators, not the register's underlying records. Commitments and public transaction data still require privacy review.
- The optional watchtower and freshness guidance is not a watchtower implementation delivered or tested by this Kit. Freshness and reorg safety must not be inferred from `isFinalAsOf`.

The following are **not claimed as completed**: live public-network production deployment, independent registrar operation, a production proof-verifier deployment, recovery under production load or institutional source integration. Local and testnet results are not a security audit or a production-readiness guarantee.

## Verification

### Kit baseline

This repository was restored on 2026-11-06 after the original `GiraffeTechnology` account was closed. The code is the Kit snapshot at `1b4b4e6`, plus the record-date consumer example recovered from its contributor's branch. The earlier baseline commit `93035d2` and its CI run are no longer reachable. Run the full check from a fresh checkout:

```sh
npm ci
npm run verify
```

CI runs the same `verify` on Node 22 and 24 for every pull request.

Individual checks:

```sh
npm run typecheck
npm run coverage
npm run test:onchain
python3 sdk/python/test_client.py
```

The tests cover historical query boundaries, same-holder confirming entries, proof binding and failures, cancellation without finality, transfer and projection separation, and the consumer's same-block gap case. The [test-to-implementation evidence map](docs/DELIVERY-EVIDENCE.md) gives historical component evidence; some stage descriptions and suite counts refer to earlier revisions.

### Public testnet evidence

[Integration test results](docs/testing/TEST-RESULTS-2026-10-19.md) record a wallet campaign of 60 scoped cases, all with recorded PASS results in their stated execution scopes, plus a same-block release and admission ordering campaign on the public Hoodi testnet (chain ID 560048). A [machine-readable receipt index](docs/testing/hoodi-receipts.json) lists the transactions. Assets and register inputs were synthetic; transaction execution and receipts are public-chain facts. These results are separate from the Kit suite counts above and are version-pinned evidence, not a certification of every normative requirement.

## Documentation and contributions

- [Semantic model](docs/ERC8415-SEMANTIC-MODEL.md) and [gap semantics](docs/GAP-SEMANTICS.md)
- [API](api/README.md), [SDKs](sdk/README.md) and [development commands](docs/DEVELOPMENT.md)
- [ERC-8415 discussion](https://ethereum-magicians.org/t/erc-8415-asynchronous-register-projection-for-nfts/29634) and [Kit discussion](https://ethereum-magicians.org/t/erc8415-kit-reference-implementation-now-public-cc0/29724)

Thanks to [babyblueviper1](https://github.com/babyblueviper1) for the record-date consumer contribution ([original commit](https://github.com/babyblueviper1/ERC8415-Kit/commit/f13fe0c8718c34197c14b60e13523621b81255f7)). Reproductions and integration reports are welcome: include the commit, runtime versions, command, expected result and observed result so others can rerun the case.

## License

[CC0 1.0 Universal (CC0-1.0)](LICENSE).
