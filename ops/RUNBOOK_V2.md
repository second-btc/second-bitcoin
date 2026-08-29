# RUNBOOK_V2 — Second Bitcoin v2 (one-shot broad lottery) genesis

The v1 `RUNBOOK.md` is obsolete for v2. Follow THIS file. Design/params: `ops/GENESIS_V2.md`. Eligibility rule:
`lottery/ELIGIBILITY_SPEC_V2.md`. Everything a human does at genesis is here; after `seal()` the coin runs itself.

**Genesis-day model (decided 2026-08-27): B = the genesis block itself.** Deploy fixes B; the snapshot,
commit and seal follow the deploy as fast as the eligibility evaluation completes (hours–days; no protocol
deadline — B is archival, a failed run can simply be re-run). Two human actions total, both signatures:
**(1) `ops/genesis_deploy.sh`, (2) `commitSet` + `seal`.** Everything else is scripted/automated.

Prereqs: Foundry (`forge`,`cast`), Python 3.9+, keystore key (`cast wallet import 2btc-operator`), archive
RPC access for BOTH chains (`~/.config/2btc/{base,eth}-rpc.txt`, plus optional `BASE_RPC_URLS`/`ETH_RPC_URLS`
rotation lists), ~0.01 ETH on Base for gas. **Never paste keys/seeds/passwords anywhere but the local prompt.**

---

## PHASE 0 — BEFORE deploy (state: DONE except the last two)

- [x] **N sanity** — measured 2026-08-26: eligibility rate 2.43% of active senders → N ≈ 70k–240k ≫ WINNERS0
      24,000 (win rate ~10–33%). WINNERS0 stays 24,000 (budget-fixed; odds float with N).
- [x] **Beacon on Base mainnet** — EIP-4788 returns non-zero roots (verified 2026-08-25; `ops/seal_timestamp.py`).
- [x] **Fork rehearsal** — atomic launch + beacon + Uniswap fork tests pass on real Base state (2026-08-27).
      46 local + 5 fork tests green. (Sepolia rehearsal waived by user in favor of fork+unit coverage.)
- [x] **Pre-scan** — `snapshot_v2.py scan` builds the resumable sender DBs (`lottery/scan/{base,eth}.db`)
      ahead of deploy, so only a small tail is scanned after B exists.
- [x] **Legal** — agent-level review only (user decision 2026-08-25); professional counsel skipped.
- [ ] **Genesis deploy** (Phase 1).
- [ ] **Repo public + site** at deploy time.

## PHASE 1 — Deploy (ONE command, one signature)

```bash
ops/genesis_deploy.sh     # predicts token addr from live nonce → pool params → forge deploy (atomic launch)
```
The script aborts in simulation if the address prediction or token/WETH ordering is stale (DeployV2.s.sol
guards) — safe to re-run. Output ends with **GENESIS B** (the deploy block) = the snapshot block.

- [ ] Record `TOKEN`, `pool`, `vesting`, **B**.
- [ ] **Publish now**: `gh repo edit second-btc/second-bitcoin --visibility public`; push whitepaper (KO+EN),
      `ELIGIBILITY_SPEC_V2.md`, `snapshot_v2.py`, site. Announce B. (Trading is live from this block; the
      draw seals after the list is built — say so plainly: "list building, commit within days".)

## PHASE 2 — Snapshot at B (automated; run as soon as B is L1-finalized, ~20–40 min)

```bash
cd lottery
export BASE_RPC_URL=... ETH_RPC_URL=...            # or BASE_RPC_URLS/ETH_RPC_URLS rotation lists
python3 snapshot_v2.py build --genesis-block <B> \
    --scan-db-base scan/base.db --scan-db-eth scan/eth.db \
    --exclude <token>,<vesting>,<pool>,<founder> --out data_v2
# → data_v2/eligible.txt, candidates.txt, header.json (setRoot, N, header_keccak)
python3 build_v2_proofs.py --addresses data_v2/eligible.txt --out ../site/data
```
- [ ] **Assert `N (header) == len(eligible.txt) == leaf count`** and `N ≥ 24,000` (commitSet requires it).
- [ ] **Publish `eligible.txt` + `candidates.txt` + `header.json` BEFORE committing on-chain**; announce
      `header_keccak` so third parties can reproduce first.

## PHASE 3 — Commit + seal (one sitting, two txs, user signs)

```bash
python3 ../ops/seal_timestamp.py 20    # block-ALIGNED sealTimestamp ~20 min out (≤ 2h lead)
cast send $TOKEN "commitSet(bytes32,uint256,uint64)" <setRoot> <N> <sealTs> --rpc-url $RPC --account 2btc-operator
# after sealTs passes, ANYONE can seal:
cast send $TOKEN "seal()" --rpc-url $RPC --account 2btc-operator
# missed beacon slot? retarget (permissionless, refused when a beacon exists) and seal again:
cast send $TOKEN "retarget(uint64)" <newSealTs> --rpc-url $RPC --account 2btc-operator
```
- [ ] Confirm `genesisSeed != 0`, `startTime` set, committer powerless.

## PHASE 4 — Distribution (autonomous)

- [ ] `site/config.js` token = $TOKEN; dashboard live (claim window = 180 days from seal).
- [ ] Winners `claimDraw(proof)` from their own address; proofs at `site/data/proof/<addr>.json`.
- [ ] After 180 days anyone calls `sweepDraw()`; unclaimed burns. Founder's 160 vest over 2 years
      (`FounderVestingV2.release()`, permissionless). No operator, ever.

---

## One-shot / no-undo items (get these right)
COMMITTER address · FOUNDER address · setRoot & N (commitSet, one-shot) · sqrtPrice/ticks (seedPool, one-shot,
LP burned; guarded by the deploy script's prediction asserts) · sealTimestamp parity (helper). A verified
reproduction (Phase 2 publish → anyone runs `snapshot_v2.py verify`) is the check on the list; there is no
on-chain fix after commit.
