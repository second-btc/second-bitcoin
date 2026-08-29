#!/usr/bin/env python3
"""Draw the winners of epoch k and build the Merkle tree.

usage: run_draw.py --epoch K --btc-height H --btc-hash 0x... --cap-units N --snapshot data/epoch_K/snapshot.csv
writes: data/epoch_K/winners.json  (public list + root)   data/epoch_K/proofs.json (for the claim site)
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lottery import draw, load_config, load_snapshot  # noqa: E402
from merkle import MerkleTree, leaf_hash  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--epoch", type=int, required=True)
    ap.add_argument("--btc-height", type=int, required=True)
    ap.add_argument("--btc-hash", required=True)
    ap.add_argument("--cap-units", type=int, required=True, help="epoch cap in base units (1 coin = 1e8)")
    ap.add_argument("--snapshot", required=True)
    ap.add_argument("--config", default=os.path.join(os.path.dirname(__file__), "config.json"))
    ap.add_argument("--out-dir", default=None)
    a = ap.parse_args()

    cfg = load_config(a.config)
    snapshot, digest, header = load_snapshot(a.snapshot)
    if str(header.get("epoch", a.epoch)) != str(a.epoch):
        sys.exit(f"snapshot header says epoch {header.get('epoch')}, not {a.epoch}")
    if a.epoch == 0 and header.get("h0") and int(header["h0"]) != a.btc_height:
        sys.exit(f"genesis height mismatch: header h0={header['h0']} but --btc-height {a.btc_height}")
    winners = draw(snapshot, a.epoch, a.btc_hash, a.cap_units, cfg)
    leaves = [leaf_hash(a.epoch, addr, amt) for addr, amt in winners]
    tree = MerkleTree(leaves)

    out_dir = a.out_dir or os.path.dirname(os.path.abspath(a.snapshot))
    os.makedirs(out_dir, exist_ok=True)
    total = sum(amt for _, amt in winners)
    winners_doc = {
        "token": cfg["token"]["symbol"],
        "epoch": a.epoch,
        "btc_height": a.btc_height,
        "btc_hash": a.btc_hash.lower(),
        "snapshot_sha256": digest,
        "snapshot_header": header,
        "snapshot_size": len(snapshot),
        "cap_units": a.cap_units,
        "distributed_units": total,
        "count": len(winners),
        "root": "0x" + tree.root.hex(),
        "winners": [{"address": addr, "amount_units": amt} for addr, amt in winners],
    }
    with open(os.path.join(out_dir, "winners.json"), "w") as f:
        json.dump(winners_doc, f, indent=1)
    proofs = {
        addr: {"amount_units": amt, "proof": ["0x" + p.hex() for p in tree.proof(leaf_hash(a.epoch, addr, amt))]}
        for addr, amt in winners
    }
    with open(os.path.join(out_dir, "proofs.json"), "w") as f:
        json.dump({"epoch": a.epoch, "root": "0x" + tree.root.hex(), "proofs": proofs}, f, separators=(",", ":"))
    assert total == a.cap_units or len(winners) == len(snapshot), "cap not fully distributed"
    print(f"epoch {a.epoch}: {len(winners)} winners, {total/1e8:.8f} coins, root 0x{tree.root.hex()}")
    print(f"snapshot sha256 {digest} ({len(snapshot)} addresses)")


if __name__ == "__main__":
    main()
