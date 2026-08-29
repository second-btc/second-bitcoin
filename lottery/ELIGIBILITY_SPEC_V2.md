# Second Bitcoin (2BTC) — Eligibility Spec v2 (one-shot broad lottery)

**Canonical, deterministic definition of the eligible-address set.** This is the rule that is published with
the contract at deployment. Any competent third party who follows it against an archive node must reproduce the
**identical** address list, and therefore the identical Merkle `setRoot` and count `N` committed on-chain. That
bit-exact reproducibility is the entire trust guarantee (whitepaper §3.2): the founder builds the list, but
anyone can rebuild it and compare hash-for-hash.

Rule id: **`2btc-v2-oneshot`**. Everything below is pinned to a single definition; there is no discretion.

Design principles that make it reproducible:
- **Consensus reads only.** Every predicate uses `eth_getBalance`, `eth_getTransactionCount` (nonce), and
  `eth_getCode` at a fixed historical block — values every honest **archive** node agrees on. Indexer-derived
  fields (Etherscan "first seen"/"txn count", Dune "distinct months", internal-tx counts) are **forbidden**;
  they differ by provider.
- **Two chains: Base + Ethereum L1**, combined (a veteran L1 wallet cannot be a freshly-farmed one).
- **ETH-denominated**, so no price oracle and no timezone/USD ambiguity.

---

## 1. Snapshot block B and the L1 mapping

- **B (Base)** := **the token's genesis block** — the Base block in which the deployment transaction landed.
  Nobody picks B's exact value (transaction inclusion does); by the time the rules are public, B and every
  balance leg below (B and B−2 weeks) are already history, so no one can read the rules and then fund or
  create wallets to qualify. *(Decided 2026-08-27; supersedes the earlier "pre-announced future block" design —
  strictly stronger against third-party farming, and the founder-side residual is unchanged and disclosed in §3.2
  of the whitepaper.)*
- **T_B** := `timestamp(B)`, recorded in the committed header. Equivalently B = the first Base block with
  `timestamp ≥ T_B` (Base timestamps are strictly increasing — the builder asserts this round-trip).
- Reads are taken only after B is **L1-finalized** (safe head), so no reorg can change them.
- **B₂ (Base, two weeks prior)** := the first Base block with `timestamp ≥ T_B − 1 209 600` (14 days in seconds).
- **L (Ethereum)** := the **highest Ethereum L1 block with `timestamp ≤ timestamp(B)`** (binary search).
- **L₂ (Ethereum, two weeks prior)** := the highest Ethereum L1 block with `timestamp ≤ timestamp(B) − 1 209 600`.

All four block numbers are computed once and **written into the committed header** (§7), so "2 weeks" has exactly
one numeric meaning and no one re-derives them differently.

## 2. Candidate universe (enumeration)

Every eligible address must have sent a transaction in the recent window (predicate §3.4), so enumerating recent
senders is *complete* — no eligible address is missed. Candidate set :=

```
{ a : a = tx.from of some Base block in (B − W_base , B] }
  ∪ { a : a = tx.from of some Ethereum block in (L − W_l1 , L] }
```

- **W_base**, **W_l1**: exact block counts, published in the header. W_base covers ~14 days of Base blocks;
  W_l1 covers ~14 days of L1 blocks. (They are block *counts*, not wall-clock, so they are deterministic.)
- *Builder note (result-identical, verifier unaffected):* the builder may enumerate ahead of time into a
  resumable per-sender highest-tx-block index and trim it to the window once B exists: `last_block` in
  `(X−W, X]` ⇔ in the window; `≤ X−W` ⇔ out. The index MUST end exactly at the anchor block — an index
  scanned past X is discarded and rebuilt (its rows past X lost their in-window history to the max-merge,
  and no nonce arithmetic may substitute: post-Pectra, an EIP-7702 authorization bumps an account's nonce
  without any sent transaction, so `nonce(X) > nonce(X−W)` does NOT imply the address sent in the window).
  A verifier can always re-derive the set by scanning the window's blocks directly; both derivations are
  provably equal. Membership comes only from `tx.from` appearances in scanned blocks — never from nonces.
- The deduplicated, **lowercase-sorted** candidate dump is published as a committed artifact, and **its keccak256
  hash is bound into the header**, so reproduction does not depend on re-scanning a flaky RPC — a verifier can
  start from the same raw input and only needs to re-check the predicates.

## 3. Per-candidate predicates (ALL must hold, evaluated at the fixed blocks above)

Let `balBase(a,blk)`, `balL1(a,blk)` = `eth_getBalance` (wei); `nonceBase(a,blk)`, `nonceL1(a,blk)` =
`eth_getTransactionCount`; `code(a,blk)` = `eth_getCode`.

**3.1 Assets** — combined ETH balance in range at **both** timepoints:
```
bal_now  = balBase(a,B)  + balL1(a,L)
bal_2wk  = balBase(a,B₂) + balL1(a,L₂)
eligible_assets = (1e17 ≤ bal_now < 4e19) AND (1e17 ≤ bal_2wk < 4e19)
```
Floor **0.1 ETH = 100000000000000000 wei, inclusive**; cap **40 ETH = 40000000000000000000 wei, exclusive**.

**3.2 Account age ≥ 12 months** — had already sent an outbound tx by the 12-months-before cutoff, on either chain:
```
B_age = highest Base     block with timestamp ≤ (ts_B − 31 536 000)   # 365 days before B
L_age = highest Ethereum block with timestamp ≤ (ts_B − 31 536 000)
eligible_age = ( nonceBase(a, B_age) ≥ 1 ) OR ( nonceL1(a, L_age) ≥ 1 )
```
This is exactly "first outbound tx ≥ 365 days before B, taking the earlier chain" — if the account had sent any
tx by the cutoff block, its first tx was at or before that block, i.e. age ≥ 365 days. It is a single consensus
read per chain (no binary search), so it is cheap, exact, and provider-agnostic. `B_age`/`L_age` are pinned in
the header.

**3.3 Activity 20 – 20,000 txs** — combined outbound nonce:
```
txs = nonceBase(a,B) + nonceL1(a,L)
eligible_activity = 20 ≤ txs ≤ 20 000
```
(Nonce is the only tx count with an exact, provider-agnostic consensus definition. There is **no separate
"multiple months" test** — age ≥ 12 mo together with ≥ 20 txs is the intended proxy, and it is cheap and exact.)

**3.4 Recent activity** — sent a tx in the enumeration window on either chain. Defined **identically** to §2 so
the universe and this predicate can never disagree:
```
eligible_recent = (a appears as tx.from in (B − W_base, B])
               OR (a appears as tx.from in (L − W_l1, L])
```
(True for every candidate by construction; stated for completeness.)

**3.5 Plain wallet** — EOA, or an EIP-7702-delegated account, at B only:
```
c = code(a, B)
eligible_wallet = (c == "0x") OR (c starts with 0xef0100 AND length(c) == 23 bytes)
                  # EIP-7702 designator: 0xef0100 (3 bytes) ‖ 20-byte delegate address = 23 bytes = 46 hex chars
```

**Eligible** ⇔ 3.1 ∧ 3.2 ∧ 3.3 ∧ 3.4 ∧ 3.5, and `a` is not in the exclusion list (§4).

## 4. Exclusions

Remove the system addresses, committed in the header (lowercase): the token contract, the FounderVestingV2
contract, the Uniswap v3 pool (`computedPool()`), and the founder/operator address. These are never eligible.

## 5. Data source

A true **archive** node for each chain (Base and Ethereum L1), able to read historical state at B, B₂, L, L₂ and
to binary-search historical nonces. Cross-check a random sample against a second independent archive provider.
Forbidden: any indexer-derived or non-consensus field (see principles above).

## 6. Merkle tree (must reproduce the on-chain `setRoot`)

- Leaf for address `a` (lowercase, 20 bytes): `leaf = keccak256( keccak256( abi.encode(address a) ) )`
  — i.e. `abi.encode` left-pads to 32 bytes, hash, hash again. (Matches `lottery/build_v2_proofs.py` and the
  contract's `claimDraw` / `ProofGenCrossCheck.t.sol`.)
- **Sort leaves ascending**, then build with **commutative pairing** `keccak256( min(x,y) ‖ max(x,y) )`, an **odd
  node promoted unchanged** to the next level. Root = `setRoot`.
- The **canonical builder is `lottery/build_v2_proofs.py` (with `lottery/merkle.py`)** — ship exactly this code;
  a verifier using a different library (e.g. OZ `@openzeppelin/merkle-tree`, which shapes odd nodes differently)
  can get a different root from the identical set, so the builder is part of the spec.
- `N` (`eligibleCount`) committed on-chain **MUST equal the number of leaves** (the eligible list length). The
  contract cannot check this, so it is a genesis-discipline requirement: `eligibleCount == len(list)`. (An
  understated N inflates the win rate and can push realized pieces past the `DRAW` budget → late winners revert.)

## 7. Committed header (hashed with the list)

Published and hashed together with the address list so every parameter is bound:
```
{ rule: "2btc-v2-oneshot",
  T_B, B, B2, L, L2,           // the five block anchors (numbers + timestamps)
  W_base, W_l1,                // enumeration window block counts
  floor_wei: 100000000000000000, cap_wei: 40000000000000000000,
  min_age_s: 31536000, min_txs: 20, max_txs: 20000,
  exclusions: [ ...lowercase addresses... ],
  candidates_keccak: 0x...,    // hash of the deduped, sorted raw candidate dump
  setRoot: 0x..., N: <len> }
```

## 8. Output → on-chain

The eligible list (one lowercase `0x` address per line) feeds `lottery/build_v2_proofs.py`, which emits `setRoot`,
`N`, and per-address `proof/<addr>.json`. The founder calls `commitSet(setRoot, N, sealTimestamp)`; anyone verifies
by re-running this spec from the committed header and comparing `setRoot`/`N` hash-for-hash.

## Reproducibility checklist for an independent verifier
1. Read the committed header; take the raw candidate dump and check its keccak matches `candidates_keccak`.
2. For each candidate, re-evaluate §3.1–§3.5 against an archive node at the header's block anchors.
3. Remove exclusions; sort; build the tree with `build_v2_proofs.py`.
4. Assert the resulting `setRoot` and `N` equal the on-chain `setRoot` / `eligibleCount`. Any mismatch = a
   planted or dropped address, and the exact addresses are identifiable by diffing the two sets.
