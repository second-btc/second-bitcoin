#!/usr/bin/env bash
# Base Sepolia rehearsal with YOUR keystore (password is asked locally by cast/forge — never typed into chat).
#   usage:  ops/testnet.sh            → genesis in one tx (deploy + seed pool + hand over), print the epoch commands
#   env:    ACCOUNT (keystore name, default 2btc-operator), BASESCAN_API_KEY (optional, for --verify)
#           TOKEN (reuse an existing token), P0_ETH (starting price in ETH per coin, default 0.000001)
set -eu
export PATH="$HOME/.foundry/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
ACCOUNT=${ACCOUNT:-2btc-operator}
RPC=${RPC_URL:-https://sepolia.base.org}
NPM=0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2          # Uniswap v3 NonfungiblePositionManager, Base Sepolia (verified on-chain)
WETH=0x4200000000000000000000000000000000000006
FEE=10000

ADDR=$(cast wallet address --account "$ACCOUNT")
BAL=$(cast balance "$ADDR" --rpc-url "$RPC")
echo "== operator $ADDR  balance $(python3 -c "print(int('$BAL')/1e18)") ETH on Base Sepolia (chain $(cast chain-id --rpc-url $RPC))"
if [ "$BAL" = "0" ]; then echo "fund it first: https://portal.cdp.coinbase.com/products/faucet  or  https://www.alchemy.com/faucets/base-sepolia"; exit 1; fi

cd "$ROOT/contracts"
P0=${P0_ETH:-0.000001}
echo "== pool parameters: P0 = $P0 ETH per coin (published in ETH; both orderings precomputed for the Launcher)"
eval "$(python3 "$HERE/pool_params.py" --both --p0-eth "$P0" --weth $WETH --fee $FEE)"
export NPM WETH SQRT0 TL0 TU0 SQRT1 TL1 TU1
if [ -z "${TOKEN:-}" ]; then
  echo "== GENESIS in one transaction: deploy token + seed single-sided pool + hand over operator ($ADDR)"
  VERIFY=""; [ -n "${BASESCAN_API_KEY:-}" ] && VERIFY="--verify --etherscan-api-key $BASESCAN_API_KEY --verifier-url https://api-sepolia.basescan.org/api"
  OUT=$(forge script script/Deploy.s.sol --rpc-url "$RPC" --account "$ACCOUNT" --broadcast $VERIFY 2>&1) || { echo "$OUT" | tail -20; exit 1; }
  echo "$OUT" | grep -E "Launcher|SecondBitcoin|FounderVesting|pool|position|genesis block"
  TOKEN=$(echo "$OUT" | grep "SecondBitcoin (2BTC):" | awk '{print $NF}')
fi
echo "   token $TOKEN  pool $(cast call "$TOKEN" "pool()(address)" --rpc-url "$RPC")  seeded=$(cast call "$TOKEN" "poolSeeded()(bool)" --rpc-url "$RPC")"

cat <<EOT

== next: the epoch flow (run from $ROOT; each command asks for your keystore password)
export RPC_URL=$RPC TOKEN=$TOKEN SIGNER="--account $ACCOUNT" SNAPSHOT_RPC_URL=$RPC
python3 ops/epoch.py status
python3 ops/epoch.py snapshot 0 --window 3000 --workers 4     # testnet: small window (B = deployment block, automatic)
python3 ops/epoch.py commit 0 --h0-offset 6                   # testnet: H0 = tip+6 (~1 h) instead of +36; mainnet uses the default
#   wait until Bitcoin reaches H0 + 6 confirmations (status shows it), then:
python3 ops/epoch.py draw 0 && python3 ops/epoch.py open 0 && python3 ops/epoch.py publish 0
#   claims open 24 h after open. Site: (cd site && python3 -m http.server 8080) and open
#   (localhost rehearsal) http://localhost:8080/?token=$TOKEN&rpc=$RPC&chain=84532&explorer=https://sepolia.basescan.org
EOT
