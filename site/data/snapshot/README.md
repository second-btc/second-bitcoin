# Genesis snapshot artifacts — reproduce the eligible set yourself

Snapshot block **B = 50,615,795** (the genesis block of `0x292198f6aceb505EbaD96ba7654bAe70B57c0fdd`).

| file | what |
|---|---|
| `header.json` | the committed header: block anchors, thresholds, exclusions, `candidates_keccak`, `setRoot`, `N`. Self-binding via `header_keccak`. |
| `eligible.txt` | the canonical eligible set — **N = 84,089** lowercase addresses, sorted, LF-joined (no trailing newline). |
| `../proof/<address>.json` | that address's Merkle proof against `setRoot`. |
| `candidates.txt.gz` | the 6,903,801-address candidate universe. **Published as a GitHub Release asset** (283 MB raw; GitHub rejects repo files over 100 MB). See below. |

## The numbers

```
N        = 84,089            (eligible wallets)
WINNERS0 = 24,000            (immutable contract constant)
odds     = 24,000 / 84,089  ≈ 28.5%
setRoot  = 0x40586f19308707d4dd2f4db69416ad385f2d5b07ab7c616ae9aae1ac21c69390
header   = 0x397e61965a0e3c3d584f44821b6397bb90087ffee9508291c6222b0cb9efdaf6
```

## Verify

1. **The set root** — recompute the Merkle root from `eligible.txt` and compare with `setRoot`
   (and with the value committed on-chain):
   ```bash
   python3 lottery/build_v2_proofs.py --addresses eligible.txt --out /tmp/check --limit 0
   cast call 0x292198f6aceb505EbaD96ba7654bAe70B57c0fdd "setRoot()(bytes32)" --rpc-url https://mainnet.base.org
   ```

2. **The candidate universe** — the header binds `candidates_keccak = keccak256(file bytes)` of the
   LF-joined sorted candidate list. Fetch the release asset and check it:
   ```bash
   gh release download snapshot-b50615795 -p candidates.txt.gz -R second-btc/second-bitcoin
   gunzip -c candidates.txt.gz > candidates.txt          # 283 MB
   python3 -c "import sys;sys.path.insert(0,'lottery');from keccak import keccak256;\
   print('0x'+keccak256(open('candidates.txt','rb').read()).hex())"
   # must equal header.json → candidates_keccak
   ```
   You do not have to trust this file: `lottery/ELIGIBILITY_SPEC_V2.md` §2 defines the candidate set as the
   senders of the window's blocks, so you can re-derive it from any archive node and get the same set.

3. **The whole list, end to end** — re-run the same predicate code against archive nodes and diff:
   ```bash
   BASE_RPC_URL=<base archive> ETH_RPC_URL=<eth archive> \
   python3 lottery/snapshot_v2.py verify \
       --header header.json --candidates candidates.txt \
       --expect-root 0x40586f19308707d4dd2f4db69416ad385f2d5b07ab7c616ae9aae1ac21c69390 \
       --expect-n 84089
   ```
   `verify` re-derives the block anchors from `T_B`, refuses a header whose parameters differ from the
   verifier's own constants, and re-reads every consensus value (no derived shortcuts). It exits non-zero
   on any mismatch. This reproduction — not anyone's word — is the guarantee.
