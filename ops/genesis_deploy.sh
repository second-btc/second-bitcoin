#!/bin/zsh
# Second Bitcoin v2 — one-command genesis deploy (run by the operator; the ONLY manual step besides commit+seal).
# Predicts the token address from the LIVE nonce, computes pool params for that exact address, then deploys
# atomically (Launcher: token + single-sided pool in one tx). The forge simulation re-checks the prediction
# and aborts before broadcasting if anything is stale (see DeployV2.s.sol guards).
set -e
cd "$(dirname "$0")/.."

RPC=$(cat ~/.config/2btc/base-rpc.txt)
DEPLOYER=0xcabf0054e960df6dfe187ee94ff328a3e92648d5
P0_ETH=0.014285714   # 0.1 ETH / 7 — an arbitrary starting tick, not a valuation (whitepaper §6)

NONCE=$(cast nonce $DEPLOYER --rpc-url $RPC)
LAUNCHER=$(cast compute-address $DEPLOYER --nonce $NONCE | awk '{print $NF}')
TOKEN=$(cast compute-address $LAUNCHER --nonce 1 | awk '{print $NF}')
echo "deployer $DEPLOYER (nonce $NONCE)"
echo "predicted launcher $LAUNCHER"
echo "predicted token    $TOKEN"

python3 ops/pool_params.py --token $TOKEN --p0-eth $P0_ETH --json > /tmp/2btc_pp.json
export SQRT_PRICE_X96=$(python3 -c "import json; print(json.load(open('/tmp/2btc_pp.json'))['sqrtPriceX96'])")
export TICK_LOWER=$(python3 -c "import json; print(json.load(open('/tmp/2btc_pp.json'))['tickLower'])")
export TICK_UPPER=$(python3 -c "import json; print(json.load(open('/tmp/2btc_pp.json'))['tickUpper'])")
export WE_ARE_TOKEN0=$(python3 -c "import json; print('true' if json.load(open('/tmp/2btc_pp.json'))['weAreToken0'] else 'false')")
python3 -c "import json; r=json.load(open('/tmp/2btc_pp.json')); print('P0 effective:', r['p0_eth_effective'], 'ETH/coin, token0=', r['weAreToken0'])"
if [ -z "$SQRT_PRICE_X96" ] || [ -z "$TICK_LOWER" ] || [ -z "$TICK_UPPER" ] || [ -z "$WE_ARE_TOKEN0" ]; then
  echo "!! pool params failed - aborting before any broadcast"; exit 1
fi
export COMMITTER=$DEPLOYER FOUNDER=$DEPLOYER DEPLOYER

echo ""
echo ">>> deploying (password prompt = keystore 2btc-operator)"
cd contracts
forge script script/DeployV2.s.sol --rpc-url $RPC --account 2btc-operator2 --sender $DEPLOYER --broadcast -vv

echo ""
echo ">>> genesis facts"
RUN=broadcast/DeployV2.s.sol/8453/run-latest.json
python3 - "$RUN" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))
txs = r["transactions"]; rcs = r.get("receipts", [])
for t, rc in zip(txs, rcs):
    if t.get("transactionType") == "CALL":  # launcher.launch(...)
        print("launch tx   :", rc["transactionHash"])
        print("GENESIS B   :", int(rc["blockNumber"], 16))
print("record B above — it is the snapshot block. Next:")
print("  python3 ../lottery/snapshot_v2.py build --genesis-block <B> \\")
print("      --scan-db-base ../lottery/scan/base.db --scan-db-eth ../lottery/scan/eth.db \\")
print("      --exclude <token>,<vesting>,<pool>,<founder> --out ../lottery/data_v2")
EOF
