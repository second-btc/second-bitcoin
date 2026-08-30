# Second Bitcoin (2BTC) — a second chance at a fair start

210,000 coins (1/100 of Bitcoin), 8 decimals, on Base. Distribution is a **single act of redistribution at genesis**:
about 90% of the supply (188,790 coins) goes to wallets that already exist, drawn at random from one sealed
seed. No registration, no presale, no treasury. Each wallet's share and amount are a pure function of the sealed
seed and its own address, so recipients **claim for themselves** and there is no recipients' list to trust. The
founder keeps 0.1% (210 coins), disclosed, the locked part released over two years behind everyone else. After
the genesis seal, no operator ever acts.

Read the whitepaper: [English](whitepaper/second_bitcoin_en.md) · Dashboard / claim page:
https://second-btc.github.io/second-bitcoin/

> The `*V2` / `_v2` names below mark the released design; older files are kept in-tree for history.


## Genesis (Base mainnet, 2026-08-30)

- Token **2BTC**: [`0x292198f6aceb505EbaD96ba7654bAe70B57c0fdd`](https://basescan.org/address/0x292198f6aceb505EbaD96ba7654bAe70B57c0fdd)
- **Snapshot block B = 50,615,795** — the genesis block itself (see the whitepaper §3 and `lottery/ELIGIBILITY_SPEC_V2.md`)
- Pool (Uniswap v3, single-sided): `0xe052A3ac23A0F1485aCF3c04DeEC5F51e79eC522` · Vesting: `0x9328F70aCCa80D99F580E1D9170D9C03d4b88D90`
- Eligible-set build in progress; `commitSet` + `seal` follow. Reproduce with `lottery/snapshot_v2.py`.

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
BASE_RPC_URL=<base archive> ETH_RPC_URL=<eth L1 archive> \
python3 lottery/snapshot_v2.py verify \
    --header data_v2/header.json --candidates data_v2/candidates.txt \
    --expect-root <on-chain setRoot> --expect-n <on-chain eligibleCount>
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
