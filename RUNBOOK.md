> ⚠️ **LEGACY (v1, 33-epoch draw). The live design is one-shot — follow `ops/RUNBOOK_V2.md` instead.** This file
> is kept for history; its `epoch.py commit/draw/open`, Bitcoin-block seed, and per-epoch steps do not exist in v2.

# RUNBOOK — launch and operations

Prerequisites: Foundry (`forge`, `cast`, `anvil`), Python 3.9+, a keystore for the operator key (`cast wallet import 2btc-operator --interactive`). Never paste keys, seeds or passwords anywhere but the local prompt. All commands from the repository root.

## 1. Rehearsal without real funds
- Local fork of Base mainnet with real Uniswap v3: `ops/rehearsal_fork.sh` (deploy + seed + buy/sell + epoch 0 + claim), `ops/cli_dryrun.sh` (operator CLI end to end incl. verification), `ops/rehearse_with_keystore.sh up|genesis` (same, signing with your keystore).
- Base Sepolia: `ops/testnet.sh` (genesis in one transaction), then the epoch commands it prints.

## 2. Mainnet genesis (one day)
Checklist: name collisions re-checked on DEX Screener/Basescan · `lottery/config.json` frozen (rule v4; exclusion list = token, vesting, pool, founder/operator) · whitepaper Appendix A filled (P₀ in ETH, addresses once known) · repository and dashboard public the same day as deployment · operator wallet holds ≈ 0.005 ETH on Base · (recommended) an archive RPC with batch support for snapshots (`SNAPSHOT_RPC_URL`).

```bash
export PATH="$HOME/.foundry/bin:$PATH"
export RPC_URL=https://mainnet.base.org SIGNER="--account 2btc-operator" SNAPSHOT_RPC_URL=<archive rpc>
# 1) genesis = one transaction: deploy + single-sided pool (no ETH) + hand-over. P0 published in Appendix A first.
cd contracts && eval "$(python3 ../ops/pool_params.py --both --p0-eth <P0_ETH>)" && export NPM=0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1 WETH=0x4200000000000000000000000000000000000006 SQRT0 TL0 TU0 SQRT1 TL1 TU1
forge script script/Deploy.s.sol --rpc-url $RPC_URL --account 2btc-operator --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
export TOKEN=0x...   # "SecondBitcoin (2BTC):" in the output
cd ..
# 2) exclusion list: lottery/config.json eligibility.exclude = [token, vesting, pool, founder/operator] (lowercase) — never changed afterwards
# 3) genesis list: B = deployment block (automatic); floor $100 / cap $100,000 of ETH from the public rate at snapshot time
python3 ops/epoch.py snapshot 0 --workers 8            # hours on a public RPC, 15–40 min on a keyed one
git add lottery/data/epoch_0 && git commit -m "epoch 0 list" && git push      # the list is public BEFORE the commit
# `commit 0` rewrites the header with H0 and WAITS: push the committed bytes, then press Enter to broadcast.
git add lottery/data/epoch_0 && git commit -m "epoch 0 committed list" && git push   # do this when commit 0 pauses
python3 ops/epoch.py commit 0                          # sets H0 = Bitcoin tip + 36 (≈ 6 h), fixes it on-chain; one shot
# 4) after H0 + 6 confirmations
python3 ops/epoch.py draw 0 && python3 ops/epoch.py open 0 && python3 ops/epoch.py publish 0
python3 lottery/verify.py --epoch 0 --snapshot lottery/data/epoch_0/snapshot.csv --winners lottery/data/epoch_0/winners.json --rpc $RPC_URL --token $TOKEN --mempool https://mempool.space/api --completeness 200 --rederive 200
git add lottery/data/epoch_0 site/data && git commit -m "epoch 0 draw" && git push
```

## 3. Every epoch (epoch k lasts 2,100·(k+1) Bitcoin blocks: 2 weeks, 4 weeks, 6 weeks …)
```bash
python3 ops/epoch.py status                 # blocks/hours to H_k, what is due
# ≥ 36 Bitcoin blocks (≈ 6 h) before H_k — start the snapshot ~12 h before; publish the list, then commit (the tool refuses inside the margin):
python3 ops/epoch.py snapshot K && git add lottery/data/epoch_K && git commit -m "epoch K list" && git push && python3 ops/epoch.py commit K
# after H_k + 6 confirmations:
python3 ops/epoch.py draw K && python3 ops/epoch.py open K && python3 ops/epoch.py publish K
git add lottery/data/epoch_K site/data && git commit -m "epoch K" && git push
```
- Verifier tiers for the commit lead: ≥ 4 h OK · 2–4 h LATE (warning) · < 2 h TAINTED. A commit is one-shot; a wrong or late one → `python3 ops/epoch.py skip K` (half burned, half to K+1, no founder unlock) and publish the reason.
- Open only after 6 confirmations (the tool cross-checks two explorers). Claims open 24 h after the root and close two weeks later or when the next epoch opens (epoch 0: epoch 1 opens ≈ a day before the two weeks are up); unclaimed: half burned, half carried when the next epoch opens.
- Epoch 1 only: epoch 0's claim window is still open while you draw, so run `draw 1` and `open 1` back to back; `open` aborts if the cap moved — re-run `draw 1`. If a claim still slips in between, publish the shortfall (half of each in-between claim, ≤ 25 coins per claim, borne by epoch 1's last claimant).
- Whitepaper/site copy: after editing `whitepaper/second_bitcoin_en.md` run `python3 whitepaper/build.py && cp whitepaper/second_bitcoin_en.{html,pdf} site/whitepaper/`.
- After epoch 32's window anyone may call `finalize()`; after two years without open/skip anyone may call `abandon()`.
- Founder vesting: `cast send <vesting> "release()"` (anyone may call; funds go to the founder).

## 4. Snapshot data sources
- Candidate enumeration (senders in the window): `--scan` via RPC (universal, slow), or a Dune export (`SELECT DISTINCT "from" FROM base.transactions WHERE block_number BETWEEN B-629999 AND B`) / Envio HyperSync → `--candidates` file.
- Balance / code / nonce checks need an archive RPC. The public `mainnet.base.org` serves archive state but caps batches at 10 and rate-limits → prefer a keyed endpoint (`--batch 100 --workers 8`).
- Verifiers reproduce everything from the header (block, l1block, min, ethusd, h0, max0, exclude). If snapshot.csv exceeds GitHub's 100 MB limit, pin it to IPFS and add `"mirror": "<url>"` to that epoch's snapshot.meta.json before committing.

## 5. Measured on a Base mainnet fork (2026-08)
genesis (deploy + seed, one tx) ≈ 8.6 M gas · commit ≈ 78 k · open ≈ 138 k · claim ≈ 100 k · swap ≈ 140–160 k. At 0.006 gwei and ETH ≈ $3,500: operator lifetime ≈ $0.3, a claim ≈ $0.002, a swap ≈ $0.003 (+ L1 data fee).
