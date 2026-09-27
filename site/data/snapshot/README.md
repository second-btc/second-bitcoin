# Genesis snapshot artifacts — reproduce the eligible set yourself

Snapshot block **B = 50,615,795** — the genesis block of `0x292198f6aceb505EbaD96ba7654bAe70B57c0fdd`
(deployed 2026-08-29 16:28:57 UTC). Sealed 2026-09-27 14:07:11 UTC. **Claims close 2027-03-26 14:07:11 UTC.**

Run every command below **from the repository root** after
`git clone --recursive https://github.com/second-btc/second-bitcoin`.

| file | what |
|---|---|
| `header.json` | the committed header: the six block anchors and their timestamps, thresholds, exclusions, `candidates_keccak`, `setRoot`, `N`. Self-binding via `header_keccak`. |
| `eligible.txt` | the canonical eligible set — **N = 84,089** lowercase addresses, sorted, LF-joined (no trailing newline). |
| `../proof/<address>.json` | that address's Merkle proof against `setRoot`, one file per eligible wallet. |

`candidates.txt.gz` — the 6,903,801-address candidate universe — is **not in this directory**: it is a
[GitHub Release asset](https://github.com/second-btc/second-bitcoin/releases/tag/snapshot-b50615795)
(283 MiB unpacked; GitHub rejects repository files over 100 MB).

## The numbers

```
N        = 84,089            (eligible wallets)
WINNERS0 = 24,000            (immutable contract constant, fixed at deployment)
odds     = 24,000 / 84,089  ≈ 28.5%
setRoot  = 0x40586f19308707d4dd2f4db69416ad385f2d5b07ab7c616ae9aae1ac21c69390
header   = 0x397e61965a0e3c3d584f44821b6397bb90087ffee9508291c6222b0cb9efdaf6
seed     = 0x354bb777e74f803330433efd44699dc308a37b9a44f891cbbace38cc8bb0734a
```

## 1. The set root

```bash
python3 lottery/build_v2_proofs.py --addresses site/data/snapshot/eligible.txt --out /tmp/check --limit 1
cast call 0x292198f6aceb505EbaD96ba7654bAe70B57c0fdd "setRoot()(bytes32)" \
  --rpc-url https://base-rpc.publicnode.com
```
Compare the printed `setRoot =` line with the `cast call` output. `--limit 1` computes the root over the whole
list but writes only one proof file; pass `--limit 0` if you want all 84,089 written out.

## 2. The candidate file you were given

The header binds `candidates_keccak` = keccak256 of the candidate file's bytes.

```bash
gh release download snapshot-b50615795 -p candidates.txt.gz -R second-btc/second-bitcoin
gunzip -c candidates.txt.gz > candidates.txt
ls -l candidates.txt        # must be exactly 296,863,442 bytes (6,903,801 × 43 − 1)
python3 -c "import sys;sys.path.insert(0,'lottery');from keccak import keccak256;\
print('0x'+keccak256(open('candidates.txt','rb').read()).hex())"   # == header.json candidates_keccak
```
The hash takes 15–20 minutes: `lottery/keccak.py` is deliberately pure Python so it needs no dependencies. The
byte count above is a free integrity pre-check if you would rather not wait.

## 3. Re-run the rule

```bash
BASE_RPC_URL=<base archive> ETH_RPC_URL=<eth archive> \
python3 lottery/snapshot_v2.py verify \
    --header site/data/snapshot/header.json --candidates candidates.txt \
    --expect-root 0x40586f19308707d4dd2f4db69416ad385f2d5b07ab7c616ae9aae1ac21c69390 \
    --expect-n 84089
```
`verify` checks `header_keccak`, refuses a header whose thresholds differ from the verifier's own constants,
re-derives the block anchors from `T_B`, and re-reads every consensus value behind every predicate — no derived
shortcuts. It exits non-zero on any mismatch.

**What step 3 does not cover.** `verify` accepts the candidate file as given: `candidates_keccak` is the hash *of
that file*, so a file that silently omitted in-window senders would still pass every check and still reproduce
`setRoot` and `N` — while the omitted addresses were wrongly excluded. Completeness of the candidate universe is
the one property the committed header cannot bind. It is checked only by step 4.

## 4. The candidate universe is complete

Re-scan the enumeration windows yourself and confirm the published set is not a subset. The windows are exact
block counts pinned in the header:

```
Base:     (B − W_base, B]  =  (49,985,795 , 50,615,795]
Ethereum: (L − W_l1,   L]  =  (25,761,306 , 25,862,106]
```

Membership is `tx.from` appearances in those blocks only — never nonce arithmetic (spec §2: post-Pectra an
EIP-7702 authorization bumps a nonce with no transaction sent, so a nonce difference does not imply a send).
The union, lowercased, deduplicated, sorted and LF-joined without a trailing newline, must equal
`candidates.txt` byte for byte. `lottery/snapshot_v2.py scan` will build that index for you, or scan the
blocks with any tool you trust.

Also confirm that **B = 50,615,795 is the block carrying the token's deployment transaction** (Basescan, or
`cast tx`): `verify` re-derives B from `T_B` but does not assert it is the genesis block, and the whitepaper's
"B is not a chosen block" rests on that fact.

Steps 1–3 prove the rule was applied correctly to the published input. Step 4 proves the input was complete.
Both together — not anyone's word — are the guarantee.

## A note on the deployed source

The verified contract source keeps a few pre-deployment comments: `WINNERS0 = 24_000; // provisional`, two
"finalize before deploy" items, and a `// old 70% + 19.9%` note from a superseded design. These are stale
comments only. `WINNERS0` is declared `constant` — it was fixed at deployment and cannot change, and it is the
value the odds above are computed from. The EIP-4788 call semantics flagged in one of those notes were confirmed
on Base mainnet by the seal itself: `genesisSeed` is non-zero. The contract is immutable, so the comments cannot
be edited out.

## The rule that was applied

All of, measured at B: held **at least 0.1 ETH and strictly less than 40 ETH** (Base and Ethereum balances
combined) at both B and two weeks before B · first nonce-bumping activity at least **12 months** before B, taking
the earlier of the two chains · a combined nonce between **20 and 20,000** · sent a transaction within the
enumeration window on either chain · a plain wallet (no contract code, or an EIP-7702 delegation only).
Thresholds are in ETH, so no price source or oracle is involved. The token, vesting and pool contracts and the
founder's address are excluded and named in the header. Full definition: `lottery/ELIGIBILITY_SPEC_V2.md`.
