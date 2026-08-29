#!/usr/bin/env bash
# Genesis rehearsal on a LOCAL fork of Base mainnet using YOUR keystore (real signing path, zero cost).
#   step 1 (helper runs): ops/rehearse_with_keystore.sh up        → start anvil fork on :8547, fund the keystore address
#   step 2 (you, in Terminal): ops/rehearse_with_keystore.sh genesis → deploy+seed in one tx (asks keystore password)
#   then the epoch flow printed at the end (each asks the password).
set -eu
export PATH="$HOME/.foundry/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
ACCOUNT=${ACCOUNT:-2btc-operator}
RPC=http://127.0.0.1:8547
NPM=0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1; WETH=0x4200000000000000000000000000000000000006; FEE=10000
case "${1:-}" in
  up)
    pkill -f "anvil --fork-url" 2>/dev/null || true; sleep 1
    nohup anvil --fork-url https://mainnet.base.org --port 8547 --silent --chain-id 8453 >/dev/null 2>&1 &
    for i in $(seq 1 60); do cast chain-id --rpc-url $RPC >/dev/null 2>&1 && break; sleep 1; done
    ADDR=${ADDR:?set ADDR=<operator address> (the keystore file does not expose it without the password)}
    cast rpc anvil_setBalance "$ADDR" 0xDE0B6B3A7640000 --rpc-url $RPC >/dev/null   # 1 ETH of fork ETH
    echo "fork up at $RPC (block $(cast block-number --rpc-url $RPC)); $ADDR funded with $(cast balance $ADDR --rpc-url $RPC | awk '{print $1/1e18}') fork-ETH"
    ;;
  genesis)
    ADDR=$(cast wallet address --account "$ACCOUNT")
    echo "== operator $ADDR  balance $(cast balance $ADDR --rpc-url $RPC | awk '{print $1/1e18}') ETH (fork)"
    cd "$ROOT/contracts"
    P0=${P0_ETH:-0.000001}
    eval "$(python3 "$HERE/pool_params.py" --both --p0-eth "$P0" --weth $WETH --fee $FEE)"
    export NPM WETH SQRT0 TL0 TU0 SQRT1 TL1 TU1
    echo "== GENESIS in one transaction (deploy + seed single-sided pool at P0=$P0 ETH + hand over operator)"
    OUT=$(forge script script/Deploy.s.sol --rpc-url "$RPC" --account "$ACCOUNT" --broadcast 2>&1) || { echo "$OUT" | tail -20; exit 1; }
    echo "$OUT" | grep -E "Launcher|SecondBitcoin|FounderVesting|pool  |position|genesis block"
    TOKEN=$(echo "$OUT" | grep "SecondBitcoin (2BTC):" | awk '{print $NF}')
    cat <<EOT

== genesis done. Next (same Terminal; each command asks your keystore password):
export PATH="\$HOME/.foundry/bin:\$PATH" RPC_URL=$RPC SNAPSHOT_RPC_URL=https://mainnet.base.org TOKEN=$TOKEN SIGNER="--account $ACCOUNT" DRYRUN=1
cd $ROOT
python3 ops/epoch.py status
python3 ops/epoch.py snapshot 0 --block \$(( \$(cast block-number --rpc-url https://mainnet.base.org) - 5 )) --window 30 --workers 4   # dry run: small window, public-RPC block
python3 ops/epoch.py commit 0 --h0-offset -1          # dry run: H0 = tip-1 so the draw can run now (verify will flag the lead — expected)
cast rpc evm_increaseTime 7300 --rpc-url $RPC >/dev/null; cast rpc evm_mine --rpc-url $RPC >/dev/null    # skip the 2 h commit→open lead on the fork
python3 ops/epoch.py draw 0 && python3 ops/epoch.py open 0 && python3 ops/epoch.py publish 0
cast rpc evm_increaseTime 86500 --rpc-url $RPC >/dev/null; cast rpc evm_mine --rpc-url $RPC >/dev/null   # skip the 24 h claim delay
python3 lottery/verify.py --epoch 0 --snapshot lottery/data/epoch_0/snapshot.csv --winners lottery/data/epoch_0/winners.json --rpc $RPC --token $TOKEN --mempool https://mempool.space/api
# site: (cd site && python3 -m http.server 8080) → http://localhost:8080/?token=$TOKEN&rpc=$RPC   (token/chain overrides work on localhost only)
EOT
    ;;
  *) echo "usage: $0 up | genesis"; exit 1;;
esac
