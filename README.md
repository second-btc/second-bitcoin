# Second Bitcoin (2BTC) — a second chance at a fair start

210,000 coins (1/100 of Bitcoin), 8 decimals, on Base. Distribution is a **single act of redistribution at genesis**:
about 90% of the supply (188,790 coins) goes to wallets that already exist, drawn at random from one sealed
seed. No registration, no presale, no treasury. Each wallet's share and amount are a pure function of the sealed
seed and its own address, so recipients **claim for themselves** and there is no recipients' list to trust. The
founder keeps 0.1% (210 coins), disclosed, the locked part released over two years behind everyone else. After
the genesis seal, no operator ever acts.

Read the whitepaper: [English](site/whitepaper/second_bitcoin_en.html) · [한국어](site/whitepaper/second_bitcoin_ko.html) (markdown sources in `whitepaper/`) · Dashboard / claim page:
https://second-btc.github.io/second-bitcoin/


## Genesis (Base mainnet — deployed 2026-08-29 16:28:57 UTC, sealed 2026-09-27 14:07:11 UTC)

- Token **2BTC**: [`0x292198f6aceb505EbaD96ba7654bAe70B57c0fdd`](https://basescan.org/address/0x292198f6aceb505EbaD96ba7654bAe70B57c0fdd)
- **Snapshot block B = 50,615,795** — the genesis block itself (see the whitepaper §3 and `lottery/ELIGIBILITY_SPEC_V2.md`)
- Pool (Uniswap v3, single-sided): `0xe052A3ac23A0F1485aCF3c04DeEC5F51e79eC522` · Vesting: `0x9328F70aCCa80D99F580E1D9170D9C03d4b88D90`
- **Eligible set committed** — `setRoot` `0x40586f19308707d4dd2f4db69416ad385f2d5b07ab7c616ae9aae1ac21c69390`,
  **N = 84,089** out of a 6,903,801-address candidate universe; `WINNERS0 = 24,000` → odds ≈ **28.5%**
- **Sealed** 2026-09-27 14:07:11 UTC — `genesisSeed`
  `0x354bb777e74f803330433efd44699dc308a37b9a44f891cbbace38cc8bb0734a`; `committer` is now `address(0)`, powerless
- **Claims are open until 2027-03-26 14:07:11 UTC** — exactly 180 days from the seal; unclaimed coins then burn in full
- Artifacts: [`site/data/snapshot/`](site/data/snapshot/README.md) — committed header, the eligible set, 84,089 Merkle
  proofs · candidate universe as release [`snapshot-b50615795`](https://github.com/second-btc/second-bitcoin/releases/tag/snapshot-b50615795)

### Genesis timeline

| when (UTC) | what | what power existed |
|---|---|---|
| 2026-08-29 16:28:57 | deploy + pool seeding, one atomic tx — **this block is B**, so eligibility was already determined | committer may call `commitSet` once |
| 2026-09-27 (28.9 days later) | `commitSet(setRoot, 84089, 1790439835)` — list and N fixed forever | committer may only re-aim a missed seal target |
| 2026-09-26 16:23:55 → expired | the first seal target passed unsealed for 21.7 h; its EIP-4788 beacon aged out of the ~4.5 h ring | anyone may `retarget`, and only while no valid beacon exists |
| 2026-09-27 14:04:13 | `retarget(1790517853)` | — |
| 2026-09-27 14:07:11 | `seal()` — seed fixed, `startTime` set, `committer` zeroed | **none. no operator from here on** |

The 28.9-day gap between deployment and the commit is when the eligible set was being computed: 6,903,801
candidates × ~4 archive reads each, run on free public endpoints. Eligibility itself was fixed at B before any
of it, so nothing in that window could change who qualified.

## Layout

| path | what |
|---|---|
| `contracts/src/SecondBitcoinV2.sol` | ERC-20 + one-shot self-verifying redistribution + single-sided pool seeding |
| `contracts/src/LauncherV2.sol` | genesis in one atomic transaction (deploy + seed pool) |
| `contracts/src/FounderVestingV2.sol` | founder's locked coins, linear over 2 years from seal |
| `contracts/script/DeployV2.s.sol` | deploy script (env-driven) |
| `lottery/ELIGIBILITY_SPEC_V2.md` | the canonical, deterministic eligibility rule (pinned bit-for-bit) |
| `lottery/snapshot_v2.py` | builds the eligible set from Base + Ethereum archive nodes, and verifies it |
| `lottery/build_v2_proofs.py` | eligible list → `setRoot`, `N`, and per-address Merkle `proof/<addr>.json` |
| `ops/RUNBOOK_V2.md` | genesis-day runbook (deploy → snapshot → commit → seal → claim) |
| `ops/seal_timestamp.py` | computes a valid, block-aligned `sealTimestamp` for `commitSet`/`seal` |
| `ops/pool_params.py` | Uniswap v3 price/tick math for the single-sided pool |
| `site/` | static claim page (viem): redistribution status, "do I hold a share?", claim, proofs |

## Verify the eligible set yourself

The rule (`lottery/ELIGIBILITY_SPEC_V2.md`) uses consensus reads only, so anyone with archive nodes reproduces
the exact list, `setRoot`, and `N` — hash for hash. That reproducibility is the trust guarantee.

```bash
git clone --recursive https://github.com/second-btc/second-bitcoin && cd second-bitcoin
gh release download snapshot-b50615795 -p candidates.txt.gz -R second-btc/second-bitcoin
gunzip -c candidates.txt.gz > candidates.txt      # 296,863,442 bytes

BASE_RPC_URL=<base archive> ETH_RPC_URL=<eth L1 archive> \
python3 lottery/snapshot_v2.py verify \
    --header site/data/snapshot/header.json --candidates candidates.txt \
    --expect-root 0x40586f19308707d4dd2f4db69416ad385f2d5b07ab7c616ae9aae1ac21c69390 \
    --expect-n 84089
# Full instructions — including the candidate-universe completeness check that `verify` does NOT
# perform — are in site/data/snapshot/README.md
# re-derives the block anchors from the published T_B, re-runs every predicate, rebuilds setRoot, and diffs.
```

## Develop

```bash
# contracts/lib/openzeppelin-contracts is a git submodule: clone with --recursive
cd contracts && forge test --no-match-path 'test/*Fork*.t.sol'   # 46 local tests (all suites), incl. invariants
forge test --match-path 'test/*Fork*.t.sol' --fork-url https://mainnet.base.org  # EIP-4788 + Uniswap on a real fork
```

Not an offer, not advice. No promised value; the coin may be worth nothing. Published under a pseudonym.
Unaffiliated with Bitcoin, Base, or Uniswap.
