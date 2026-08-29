#!/usr/bin/env bash
# Dry-run of the operator CLI against an Anvil fork of Base: snapshot → commit → draw → open → publish → verify
set -eu
export PATH="$HOME/.foundry/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
PUB=${FORK_URL:-https://mainnet.base.org}; PORT=${PORT:-8547}; RPC=http://127.0.0.1:$PORT
K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
FORKB=$(cast block-number --rpc-url $PUB)
anvil --fork-url $PUB --fork-block-number $FORKB --port $PORT --silent --chain-id 8453 &
ANVIL=$!; if [ -z "${KEEP:-}" ]; then trap 'kill $ANVIL 2>/dev/null || true' EXIT; fi
for i in $(seq 1 60); do cast chain-id --rpc-url $RPC >/dev/null 2>&1 && break; sleep 1; done
cd "$ROOT/contracts"
eval "$(python3 "$HERE/pool_params.py" --both --p0-eth 0.000001)"
export NPM=0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1 WETH=0x4200000000000000000000000000000000000006 SQRT0 TL0 TU0 SQRT1 TL1 TU1
OUT=$(forge script script/Deploy.s.sol --rpc-url $RPC --private-key $K0 --broadcast 2>&1)
TOKEN=$(echo "$OUT" | grep "SecondBitcoin (2BTC):" | awk '{print $NF}')
cd "$ROOT"
export RPC_URL=$RPC SNAPSHOT_RPC_URL=$PUB TOKEN=$TOKEN SIGNER="--private-key $K0" DRYRUN=1
warp() { cast rpc evm_increaseTime "$1" --rpc-url $RPC >/dev/null; cast rpc evm_mine --rpc-url $RPC >/dev/null; }
rm -rf lottery/data/epoch_0
echo "== snapshot 0 @ block $((FORKB-5)), 30-block window"; python3 ops/epoch.py snapshot 0 --block $((FORKB-5)) --window ${WINDOW:-30} --workers 4 2>&1 | grep -E '"eligible"|"candidates"|commitSnapshot'
echo "== commit 0 (dry run: H0 = tip-1 so the draw can run now; verify will mark the lead INVALID — expected)"; python3 ops/epoch.py commit 0 --h0-offset -1 2>&1 | grep -E "committing|GENESIS"
warp 7300   # contract: a root cannot be posted within 2 h of the commit

echo "== draw 0"; python3 ops/epoch.py draw 0 2>&1 | grep -E "epoch 0|winners|INVALID|TAINTED|LATE|OK"
echo "== open 0"; python3 ops/epoch.py open 0 2>&1 | grep -E "status|blockNumber" | head -2 || true
echo "== publish 0"; python3 ops/epoch.py publish 0 && ls site/data/
echo "== status"; python3 ops/epoch.py status 2>&1 | grep -E "next epoch|epochsOpened|genesisBtcHeight"
echo "== verify (incl. on-chain + explorer cross-check; 2 expected FAILs in dry run: genesis block, commit lead)"; python3 lottery/verify.py --epoch 0 --snapshot lottery/data/epoch_0/snapshot.csv --winners lottery/data/epoch_0/winners.json --rpc $RPC_URL --token $TOKEN --mempool https://mempool.space/api | tail -20
echo "TOKEN=$TOKEN ANVIL_PID=$ANVIL RPC=$RPC"
