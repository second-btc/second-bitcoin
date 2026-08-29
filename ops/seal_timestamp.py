#!/usr/bin/env python3
"""Compute a valid, block-aligned sealTimestamp for SecondBitcoinV2.commitSet()/seal() on Base.

Base blocks are exactly 2 seconds apart, so their timestamps all share one parity (odd or even) in the current
epoch. seal() looks up the EIP-4788 beacon root by EXACT block timestamp, so `sealTimestamp` must equal some
future block's timestamp = (a recent block's timestamp) + 2*k. Picking a misaligned value (wrong parity, e.g. a
round UTC minute of the wrong parity) means NO block ever has it → seal() reverts "no beacon" until a retarget.
This helper inherits the live parity exactly and also sanity-checks that the 4788 predeploy is readable.

  usage: BASE_RPC_URL=... python3 seal_timestamp.py [lead_minutes]   (default 20; keep < 120 = MAX_SEAL_LEAD)
"""
import json
import os
import sys
import urllib.request

MAX_SEAL_LEAD_MIN = 120  # contract MAX_SEAL_LEAD = 2 hours
BEACON_ROOTS = "0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02"


def rpc(url, method, params):
    req = urllib.request.Request(
        url, data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
        headers={"content-type": "application/json"},
    )
    out = json.load(urllib.request.urlopen(req, timeout=30))
    if "error" in out:
        raise RuntimeError(out["error"])
    return out["result"]


def main():
    cfg = os.path.expanduser("~/.config/2btc/base-rpc.txt")
    url = open(cfg).read().strip() if os.path.exists(cfg) else os.environ["BASE_RPC_URL"]
    lead_min = int(sys.argv[1]) if len(sys.argv) > 1 else 20
    if not (0 < lead_min < MAX_SEAL_LEAD_MIN):
        sys.exit(f"lead_minutes must be in (0, {MAX_SEAL_LEAD_MIN}); MAX_SEAL_LEAD is 2h.")

    tip = int(rpc(url, "eth_blockNumber", []), 16)
    blk = rpc(url, "eth_getBlockByNumber", [hex(tip), False])
    tip_ts = int(blk["timestamp"], 16)
    # verify cadence/parity on the last few blocks
    prev_ts = int(rpc(url, "eth_getBlockByNumber", [hex(tip - 3), False])["timestamp"], 16)
    step = (tip_ts - prev_ts) / 3
    if step != 2:
        print(f"WARNING: recent avg block time {step}s != 2s — re-check parity manually", file=sys.stderr)

    k = (lead_min * 60) // 2
    seal_ts = tip_ts + 2 * k  # same parity as the live chain, exactly on the 2s grid
    # sanity: the 4788 beacon must return a NON-ZERO 32-byte root for a recent PAST block timestamp
    past = tip_ts - 24  # 12 blocks back
    try:
        root = rpc(url, "eth_call", [{"to": BEACON_ROOTS, "data": "0x" + format(past, "064x")}, "latest"])
        ok = isinstance(root, str) and len(root) == 66 and int(root, 16) != 0
    except Exception:  # noqa: BLE001
        ok = False

    print(f"Base tip block   : {tip}  ts={tip_ts}  (parity {'odd' if tip_ts % 2 else 'even'})")
    print(f"EIP-4788 readable at a recent past ts: {'yes' if ok else 'NO — investigate before deploy'}")
    print(f"\nsealTimestamp (+{lead_min} min, block-aligned): {seal_ts}")
    print(f"  → commitSet(setRoot, N, {seal_ts})   [seal() becomes callable at that time; lead < 2h ✓]")
    print(f"  parity matches the live chain ({seal_ts % 2 == tip_ts % 2}); do NOT round to an arbitrary UTC minute.")


if __name__ == "__main__":
    main()
