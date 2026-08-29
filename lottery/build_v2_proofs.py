#!/usr/bin/env python3
"""Build the epoch-0 eligible-set Merkle tree for SecondBitcoinV2 and emit the dashboard's proof files.

The V2 leaf is address-only (no amount, no epoch), matching the contract:

    leaf = keccak256(keccak256(abi.encode(address)))          # abi.encode(address) = 32-byte left-padded

Input : a file with one lowercase 0x-address per line (the committed eligible set, e.g. snapshot output).
Output: - the Merkle root and N (for commitSet), and the salted-order note
        - <out>/proof/<address>.json = {"proof": ["0x..", ...]} for every address (served by the dashboard)

    python3 build_v2_proofs.py --addresses eligible.txt --out ../site/data

The contract computes the same leaf for msg.sender at claim time and verifies the proof against setRoot,
so any address in the published set can claim without a posted winners list.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from keccak import keccak256  # noqa: E402
from merkle import MerkleTree, verify  # noqa: E402


def leaf_v2(address: str) -> bytes:
    a = bytes.fromhex(address.lower().replace("0x", ""))
    assert len(a) == 20, f"bad address: {address}"
    encoded = b"\x00" * 12 + a  # abi.encode(address)
    return keccak256(keccak256(encoded))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--addresses", required=True, help="one lowercase 0x-address per line")
    ap.add_argument("--out", required=True, help="output dir (dashboard dataBase); writes proof/<addr>.json")
    ap.add_argument("--limit", type=int, default=0, help="only emit proof files for the first N (0 = all)")
    a = ap.parse_args()

    addrs = []
    seen = set()
    for line in open(a.addresses, encoding="utf-8"):
        s = line.strip().lower()
        if not s or s.startswith("#"):
            continue
        if not s.startswith("0x") or len(s) != 42:
            sys.exit(f"not an address: {s!r}")
        if s in seen:
            sys.exit(f"duplicate address: {s}")
        seen.add(s)
        addrs.append(s)
    if not addrs:
        sys.exit("no addresses")

    leaves = [leaf_v2(x) for x in addrs]
    by_leaf = dict(zip(leaves, addrs))
    tree = MerkleTree(leaves)
    root = tree.root

    proof_dir = os.path.join(a.out, "proof")
    os.makedirs(proof_dir, exist_ok=True)
    emit = addrs if a.limit == 0 else addrs[: a.limit]
    for addr in emit:
        lf = leaf_v2(addr)
        pr = tree.proof(lf)
        assert verify(pr, root, lf), f"self-verify failed for {addr}"
        json.dump({"proof": ["0x" + p.hex() for p in pr]}, open(os.path.join(proof_dir, addr + ".json"), "w"))

    meta = {"setRoot": "0x" + root.hex(), "eligibleCount": len(addrs), "proofsEmitted": len(emit)}
    json.dump(meta, open(os.path.join(a.out, "genesis.meta.json"), "w"), indent=1)
    print("setRoot       =", meta["setRoot"])
    print("eligibleCount =", meta["eligibleCount"], "(pass as N to commitSet)")
    print("proofs written to", proof_dir, f"({len(emit)} files)")


if __name__ == "__main__":
    main()
