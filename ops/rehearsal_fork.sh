#!/usr/bin/env bash
# End-to-end rehearsal on a local Anvil fork of Base mainnet (real Uniswap v3 contracts, zero real ETH).
#   deploy → seed single-sided pool → buy with ETH → sell back → commit/open epoch 0 → winner claims → vesting
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
FORK_URL="${FORK_URL:-https://mainnet.base.org}"
PORT="${PORT:-8546}"; RPC="http://127.0.0.1:$PORT"
NPM=0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1
ROUTER=0x2626664c2603336E57B271c5C0b26F421741e481
WETH=0x4200000000000000000000000000000000000006
FEE=10000
# anvil default accounts
K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; A0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
K1=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d; A1=0x70997970C51812dc3A010C7d01b50e0d17dc79C8

anvil --fork-url "$FORK_URL" --port "$PORT" --silent --chain-id 8453 &
ANVIL=$!; trap 'kill $ANVIL 2>/dev/null || true' EXIT
for i in $(seq 1 60); do cast chain-id --rpc-url $RPC >/dev/null 2>&1 && break; sleep 1; done
echo "== fork ready at block $(cast block-number --rpc-url $RPC)"

cd "$ROOT/contracts"
# pool params for both orderings (P0 chosen in ETH; illustrative here: 1e-6 ETH/coin)
eval "$(python3 "$HERE/pool_params.py" --both --p0-eth ${P0_ETH:-0.000001} --weth $WETH --fee $FEE)"
export NPM WETH SQRT0 TL0 TU0 SQRT1 TL1 TU1
OUT=$(forge script script/Deploy.s.sol --rpc-url $RPC --private-key $K0 --broadcast 2>&1) || { echo "$OUT" | tail -20; exit 1; }
TOKEN=$(echo "$OUT" | grep "SecondBitcoin (2BTC):" | awk '{print $NF}')
VEST=$(echo "$OUT" | grep "FounderVesting" | awk '{print $NF}')
echo "== genesis in one tx: token $TOKEN vesting $VEST"
DEPLOY_GAS=$(python3 - "$ROOT/contracts/broadcast/Deploy.s.sol/8453/run-latest.json" <<'PY'
import json,sys; j=json.load(open(sys.argv[1])); print(sum(int(r["gasUsed"],16) for r in j["receipts"]))
PY
)
SEED_GAS=0
POOL=$(cast call $TOKEN "pool()(address)" --rpc-url $RPC)
NFT=$(cast call $TOKEN "positionTokenId()(uint256)" --rpc-url $RPC | awk "{print \$1}")
echo "== pool $POOL  NFT #$NFT owner: $(cast call $NPM "ownerOf(uint256)(address)" $NFT --rpc-url $RPC)"
echo "   pool 2BTC balance: $(cast call $TOKEN "balanceOf(address)(uint256)" $POOL --rpc-url $RPC | awk '{print $1/1e8}') coins; WETH in pool: $(cast call $WETH "balanceOf(address)(uint256)" $POOL --rpc-url $RPC | awk '{print $1/1e18}') ETH"
echo "   slot0 tick: $(cast call $POOL "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)" --rpc-url $RPC | sed -n 2p)"
echo "   token poolBalance (distribution): $(cast call $TOKEN "poolBalance()(uint256)" --rpc-url $RPC | awk '{print $1/1e8}') coins; burned dust: $(cast call $TOKEN "burned()(uint256)" --rpc-url $RPC | awk '{print $1}') units"

# --- buyer: 0.01 ETH → 2BTC via SwapRouter02.exactInputSingle (ETH auto-wrapped)
BUY=$(cast send $ROUTER "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))" \
  "($WETH,$TOKEN,$FEE,$A1,10000000000000000,0,0)" --value 0.01ether --private-key $K1 --rpc-url $RPC --json)
BUY_GAS=$(echo "$BUY" | python3 -c 'import json,sys; print(int(json.load(sys.stdin)["gasUsed"],16))')
B1=$(cast call $TOKEN "balanceOf(address)(uint256)" $A1 --rpc-url $RPC | awk '{print $1}')
echo "== BUY 0.01 ETH → $(echo $B1 | awk '{print $1/1e8}') 2BTC (gas $BUY_GAS); pool WETH now $(cast call $WETH "balanceOf(address)(uint256)" $POOL --rpc-url $RPC | awk '{print $1/1e18}') ETH; tick $(cast call $POOL "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)" --rpc-url $RPC | sed -n 2p)"
# --- sell half back
HALF=$((B1/2))
cast send $TOKEN "approve(address,uint256)" $ROUTER $HALF --private-key $K1 --rpc-url $RPC >/dev/null
SELL=$(cast send $ROUTER "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))" \
  "($TOKEN,$WETH,$FEE,$A1,$HALF,0,0)" --private-key $K1 --rpc-url $RPC --json)
if [ "$(echo "$SELL" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status"))')" != "0x1" ]; then   # fork flake (upstream rate limit) → retry once
  sleep 3; SELL=$(cast send $ROUTER "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))" "($TOKEN,$WETH,$FEE,$A1,$HALF,0,0)" --private-key $K1 --rpc-url $RPC --json)
fi
SELL_GAS=$(echo "$SELL" | python3 -c 'import json,sys; r=json.load(sys.stdin); print(int(r["gasUsed"],16))'); SELL_STATUS=$(echo "$SELL" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status"))')
echo "== SELL $(echo $HALF | awk '{print $1/1e8}') 2BTC → buyer WETH $(cast call $WETH "balanceOf(address)(uint256)" $A1 --rpc-url $RPC | awk '{print $1/1e18}') ETH (gas $SELL_GAS, status $SELL_STATUS)"

# --- epoch 0: commit → open (fixture root) → winner claims → vesting check
FX="$ROOT/contracts/test/fixtures/epoch0.json"
ROOTHASH=$(python3 -c "import json;print(json.load(open('$FX'))['root'])")
SNAPHASH=0x$(shasum -a 256 "$ROOT/lottery/data/epoch_fixture/snapshot.csv" | awk '{print $1}')
C=$(cast send $TOKEN "commitSnapshot(uint256,bytes32,uint64)" 0 $SNAPHASH 910000 --private-key $K0 --rpc-url $RPC --json); COMMIT_GAS=$(echo "$C" | python3 -c 'import json,sys; print(int(json.load(sys.stdin)["gasUsed"],16))')
cast rpc evm_increaseTime 7300 --rpc-url $RPC >/dev/null; cast rpc evm_mine --rpc-url $RPC >/dev/null   # 2 h commit→open lead
O=$(cast send $TOKEN "openEpoch(uint256,uint64,bytes32,bytes32,uint32)" 0 910000 0x00000000000000000000a1b2c3d4e5f60718293a4b5c6d7e8f90112233445566 $ROOTHASH 300 --private-key $K0 --rpc-url $RPC --json); OPEN_GAS=$(echo "$O" | python3 -c 'import json,sys; print(int(json.load(sys.stdin)["gasUsed"],16))')
read -r WADDR WAMT WPROOF <<<"$(python3 -c "
import json; w=json.load(open('$FX'))['winners'][5]; print(w['account'], w['amount'], '['+','.join(w['proof'])+']')")"
cast rpc evm_increaseTime 86500 --rpc-url $RPC >/dev/null; cast rpc evm_mine --rpc-url $RPC >/dev/null   # 24 h claim delay
cast rpc anvil_impersonateAccount $WADDR --rpc-url $RPC >/dev/null; cast rpc anvil_setBalance $WADDR 0x1000000000000000 --rpc-url $RPC >/dev/null
CL=$(cast send $TOKEN "claim(uint256,uint256,bytes32[])" 0 $WAMT "$WPROOF" --from $WADDR --unlocked --rpc-url $RPC --json); CLAIM_GAS=$(echo "$CL" | python3 -c 'import json,sys; print(int(json.load(sys.stdin)["gasUsed"],16))')
echo "== EPOCH 0: commit gas $COMMIT_GAS, open gas $OPEN_GAS; winner $WADDR claimed $(cast call $TOKEN "balanceOf(address)(uint256)" $WADDR --rpc-url $RPC | awk '{print $1/1e8}') 2BTC (gas $CLAIM_GAS)"
echo "   epochsOpened=$(cast call $TOKEN "epochsOpened()(uint256)" --rpc-url $RPC)  vesting releasable=$(cast call $VEST "releasable()(uint256)" --rpc-url $RPC | awk '{print $1/1e8}') (expect 0 at genesis)"

GP=$(cast gas-price --rpc-url "$FORK_URL"); ETHUSD=${ETHUSD:-3500}
python3 - $DEPLOY_GAS $SEED_GAS $COMMIT_GAS $OPEN_GAS $CLAIM_GAS $BUY_GAS $SELL_GAS $GP $ETHUSD <<'PY'
import sys
d,s,c,o,cl,b,se,gp,eu=map(float,sys.argv[1:])
usd=lambda g: g*gp/1e18*eu
print(f"\n== COST ESTIMATE @ Base gas price {gp/1e9:.4f} gwei, ETH ${eu:.0f} (L2 execution only; L1 data fee adds ~10-30%)")
print(f"   genesis (deploy+seed, one tx) {d:,.0f} gas ≈ ${usd(d):.3f} | per epoch commit+open {c+o:,.0f} ≈ ${usd(c+o):.4f} ×33 ≈ ${usd(c+o)*33:.3f}")
print(f"   founder lifetime ≈ ${usd(d+s+(c+o)*33):.2f} | winner claim {cl:,.0f} ≈ ${usd(cl):.4f} | buy {b:,.0f} ≈ ${usd(b):.4f} | sell {se:,.0f} ≈ ${usd(se):.4f}")
PY
echo "== rehearsal complete"
