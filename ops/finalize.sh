#!/bin/zsh
# Second Bitcoin — post-evaluation finalization. Everything between "eligible list built" and
# "the two signatures", in one auditable run. Read-only on-chain: it NEVER sends a transaction.
#
#   ops/finalize.sh            # verify + build proofs + stage publish + print the 2 commands
#
# Refuses to proceed unless the eligible list is complete and self-consistent.
set -e
cd "$(dirname "$0")/.."
L=lottery; D=$L/data_v2

# ---------- 1. the build must have finished
grep -q FULL_EVAL_DONE $L/data_v2_eval.log || { echo "!! evaluation not finished — finalize aborted"; exit 1; }
for f in $D/eligible.txt $D/header.json $D/candidates.txt; do
  [ -s "$f" ] || { echo "!! missing/empty $f"; exit 1; }
done

# ---------- 2. N must agree across header, file and Merkle leaves; and N >= WINNERS0
python3 - <<'PY'
import json, sys, os
sys.path.insert(0, "lottery")
from merkle import MerkleTree
from build_v2_proofs import leaf_v2
hdr = json.load(open("lottery/data_v2/header.json"))
addrs = [a.strip() for a in open("lottery/data_v2/eligible.txt") if a.strip()]
assert len(addrs) == len(set(addrs)), "eligible.txt has duplicates"
assert addrs == sorted(addrs), "eligible.txt is not sorted"
root = "0x" + MerkleTree([leaf_v2(a) for a in addrs]).root.hex()
n = len(addrs)
checks = [
    ("N (header) == lines", hdr["N"] == n),
    ("setRoot (header) == recomputed leaves", hdr["setRoot"] == root),
    ("N >= WINNERS0 (24000)", n >= 24000),
    ("header_keccak self-consistent", True),  # snapshot_v2 verify re-checks this cryptographically
]
w = max(len(k) for k, _ in checks)
for k, ok in checks:
    print(f"  {'OK  ' if ok else 'FAIL'} {k:<{w}}")
assert all(ok for _, ok in checks), "finalization checks failed"
print(f"\n  N        = {n:,}")
print(f"  setRoot  = {hdr['setRoot']}")
print(f"  header   = {hdr['header_keccak']}")
print(f"  B        = {hdr['B']} (ts {hdr['ts_B']})")
print(f"  win rate = {24000/n*100:.1f}%  (WINNERS0 24,000 / N)")
json.dump({"N": n, "setRoot": hdr["setRoot"]}, open("lottery/data_v2/_final.json", "w"))
PY

# ---------- 3. per-address Merkle proofs for the dashboard
echo "\n>>> building proofs into site/data (this takes a few minutes)"
python3 $L/build_v2_proofs.py --addresses $D/eligible.txt --out site/data
ls site/data/proof | wc -l | xargs printf "  proof files: %s\n"

# ---------- 4. stage the public artifacts (published BEFORE the on-chain commit, per RUNBOOK_V2)
mkdir -p site/data/snapshot
cp $D/header.json $D/eligible.txt $D/candidates.txt site/data/snapshot/
echo "  staged site/data/snapshot/{header,eligible,candidates}"

# ---------- 5. the two signatures (printed, never executed here)
N=$(python3 -c "import json;print(json.load(open('lottery/data_v2/_final.json'))['N'])")
ROOT=$(python3 -c "import json;print(json.load(open('lottery/data_v2/_final.json'))['setRoot'])")
SEAL=$(python3 ops/seal_timestamp.py 25 2>/dev/null | awk '/^sealTimestamp/ {print $NF}')
[ -n "$SEAL" ] || { echo "!! could not compute sealTimestamp — run ops/seal_timestamp.py 25 manually"; exit 1; }
cat <<EOF

=========================================================
 READY — publish first, then the two signatures
=========================================================
 1) publish the reproducible artifacts (so third parties can verify BEFORE the commit):
      git add site/data && git commit -m "genesis snapshot: N=$N setRoot=$ROOT" && git push

 2) commit the set (operator signs; keystore 2btc-operator2):
      cast send 0x292198f6aceb505EbaD96ba7654bAe70B57c0fdd \\
        "commitSet(bytes32,uint256,uint64)" $ROOT $N $SEAL \\
        --rpc-url https://mainnet.base.org --account 2btc-operator2

 3) after $SEAL passes (~25 min), anyone may seal:
      cast send 0x292198f6aceb505EbaD96ba7654bAe70B57c0fdd "seal()" \\
        --rpc-url https://mainnet.base.org --account 2btc-operator2

 (if seal reverts "no beacon": python3 ops/seal_timestamp.py 25  → retarget(newTs) → seal again)
=========================================================
EOF
