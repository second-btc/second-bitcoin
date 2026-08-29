#!/usr/bin/env python3
"""Build the eligible-address snapshot for epoch k at Base block B.

Rule v4 (see whitepaper §4.1 and config.json "eligibility"):
  E_k = { a | a sent ≥1 tx in Base blocks (B-W, B]                        (1) enumeration; nonce(B) > nonce(B-W)
            ∧ regular wallet at B (no code, or EIP-7702 delegation)        (2)
            ∧ balance(a,B) ≥ MIN ∧ balance(a,B-W) ≥ MIN                   (3) $100 of ETH held through the epoch
              [epoch 0 only: balance(a,B) + balance_L1(a,L) < max0 = $100,000 of ETH at genesis — less than about a bitcoin's worth]
            ∧ (nonce(a,B) ≥ 10 ∨ nonce_L1(a,L) ≥ 1) ∧ nonce(a,B) ≤ 20,000   (4) has used the chain; not infrastructure
            ∧ [k ≥ 1: not drawn in any epoch ≤ k−1]                         (5) one wallet, one payout }
          \\ exclusions.   W = 630,000 Base blocks (≈ 14.6 days at 2 s) — one halving epoch.

usage:
  snapshot.py --epoch K --block B --rpc URL (--candidates addrs.txt | --scan) [--window 630000] [--out DIR]

  --candidates : any file containing 0x-addresses (one per line or CSV; e.g. a Dune/HyperSync export of
                 DISTINCT "from" over the window). --scan pulls the senders straight from the RPC instead
                 (fine for testnets / small windows; slow for a full mainnet window).
output:
  DIR/snapshot.csv   header line + sorted unique lowercase addresses   (commit = sha256 of this file)
  DIR/snapshot.meta.json
"""
import argparse
import hashlib
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from keccak import keccak256  # noqa: E402
from rpc import Rpc  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
PROBE_ADDR = "0x00000000000000000000000000000000002b7c00"  # arbitrary code-less address for stateOverride
ADDR_RE = re.compile(r"0x[0-9a-fA-F]{40}")
HEADER_FMT = "# 2BTC snapshot epoch={epoch} block={block} window={window} l1block={l1block} min={min_wei}{ethusd}{h0}{max0} rule=v4 exclude={exclude}\n"


def probe_selector():
    return keccak256(b"probe(address[],uint256,uint256)")[:4].hex()


def encode_probe(addrs, min_wei, max_wei):
    words = [0x60, min_wei, max_wei, len(addrs)] + [int(a, 16) for a in addrs]
    return "0x" + probe_selector() + "".join(w.to_bytes(32, "big").hex() for w in words)


def decode_bools(hexdata):
    raw = bytes.fromhex(hexdata[2:])
    off = int.from_bytes(raw[0:32], "big")
    n = int.from_bytes(raw[off:off + 32], "big")
    return [raw[off + 32 + 32 * i + 31] == 1 for i in range(n)]


def load_candidates(path):
    out = set()
    with open(path) as f:
        for line in f:
            for m in ADDR_RE.findall(line):
                out.add(m.lower())
    return out


def scan_senders(rpc: Rpc, start: int, end: int, chunk: int = 10):
    blocks = list(range(start, end + 1))
    print(f"scanning {len(blocks)} blocks for tx senders…", file=sys.stderr)
    senders = set()

    def fetch(group):
        try:
            res = rpc.batch([("eth_getBlockByNumber", [hex(b), True]) for b in group])
        except RuntimeError as e:  # e.g. "backend response too large" → fall back to one block per request
            if "large" not in str(e).lower() and len(group) == 1:
                raise
            res = [rpc.call("eth_getBlockByNumber", [hex(b), True]) for b in group]
        s = set()
        for b, blk in zip(group, res):
            if blk is None:
                raise RuntimeError(f"block {b} not returned by the RPC — refusing to build an incomplete snapshot")
            for tx in blk.get("transactions", []):
                s.add(tx["from"].lower())
        return s

    groups = [blocks[i:i + chunk] for i in range(0, len(blocks), chunk)]
    done = 0
    for s in rpc.map(fetch, groups):
        senders |= s
        done += 1
        if done % 200 == 0:
            print(f"  {done * chunk}/{len(blocks)} blocks, {len(senders)} senders", file=sys.stderr)
    return senders


def filter_eligible(rpc: Rpc, addrs, block: int, min_wei: int, max_wei: int, batch: int = 2000):
    code = open(os.path.join(HERE, "probe_bytecode.hex")).read().strip()
    addrs = sorted(addrs)
    groups = [addrs[i:i + batch] for i in range(0, len(addrs), batch)]
    print(f"probing {len(addrs)} candidates at block {block} in {len(groups)} eth_call batches…", file=sys.stderr)

    def one(group):
        data = encode_probe(group, min_wei, max_wei)
        try:
            res = rpc.call("eth_call", [{"to": PROBE_ADDR, "data": data}, hex(block), {PROBE_ADDR: {"code": code}}])
            flags = decode_bools(res)
        except Exception as e:  # noqa: BLE001 — node without stateOverride support → slow path
            print(f"  stateOverride failed ({str(e)[:80]}); falling back to per-address calls", file=sys.stderr)
            flags = []
            for a in group:
                bal = int(rpc.call("eth_getBalance", [a, hex(block)]), 16)
                if not (min_wei <= bal <= max_wei):
                    flags.append(False)
                    continue
                c = rpc.call("eth_getCode", [a, hex(block)])
                flags.append(c in ("0x", "") or c.lower().startswith("0xef0100") and len(c) == 48)
        return [a for a, ok in zip(group, flags) if ok]

    out = []
    for r in rpc.map(one, groups):
        out.extend(r)
    return sorted(set(out))


def l1_block_at_or_before(l1rpc: Rpc, ts: int) -> int:
    """Binary search: highest block with timestamp <= ts (Ethereum L1, ~12 s blocks)."""
    hi = int(l1rpc.call("eth_blockNumber", []), 16)
    lo = max(0, hi - 100_000)
    while int(l1rpc.call("eth_getBlockByNumber", [hex(lo), False])["timestamp"], 16) > ts:
        hi, lo = lo, max(0, lo - 100_000)
    while lo < hi:
        mid = (lo + hi + 1) // 2
        t = int(l1rpc.call("eth_getBlockByNumber", [hex(mid), False])["timestamp"], 16)
        if t <= ts:
            lo = mid
        else:
            hi = mid - 1
    return lo


def nonces_at(rpc: Rpc, addrs, block_tag: str, batch: int = 10):
    """eth_getTransactionCount for many addresses at a block (batched; public RPCs cap batches at 10)."""
    groups = [addrs[i:i + batch] for i in range(0, len(addrs), batch)]

    def one(group):
        return [int(x, 16) for x in rpc.batch([("eth_getTransactionCount", [a, block_tag]) for a in group])]

    out = {}
    for group, res in zip(groups, rpc.map(one, groups)):
        out.update(dict(zip(group, res)))
    return out


def balances_at(rpc: Rpc, addrs, block_tag: str, batch: int = 10):
    groups = [addrs[i:i + batch] for i in range(0, len(addrs), batch)]

    def one(group):
        return [int(x, 16) for x in rpc.batch([("eth_getBalance", [a, block_tag]) for a in group])]

    out = {}
    for group, res in zip(groups, rpc.map(one, groups)):
        out.update(dict(zip(group, res)))
    return out


def past_recipients(data_dir: str, epoch: int):
    """Every address drawn in any earlier epoch (i <= epoch-1). One wallet, one payout: being *drawn* is
    what removes an address from every later list, whether or not it claimed — so unlike the previous
    rule this needs no eth_call, and it can already apply at epoch 1 (no waiting for a window to close)."""
    out = set()
    for i in range(0, epoch):
        path = os.path.join(data_dir, f"epoch_{i}", "winners.json")
        if not os.path.exists(path):
            raise RuntimeError(f"missing {path}: earlier winners files are needed to apply rule (5)")
        w = json.load(open(path))
        for x in w["winners"]:
            out.add(x["address"].lower())
    return out


def filter_history(rpc: Rpc, l1rpc: Rpc, addrs, block: int, age_block: int, l1_block: int, el: dict, batch: int = 10):
    """Rules (1) consistency and (4): alive inside the window, has used the chain, not infrastructure."""
    addrs = sorted(addrs)
    print(f"nonce checks for {len(addrs)} addresses at blocks {age_block} and {block}…", file=sys.stderr)
    n_old = nonces_at(rpc, addrs, hex(age_block), batch)
    n_now = nonces_at(rpc, addrs, hex(block), batch)
    minn, maxn = int(el["base_min_nonce"]), int(el["base_max_nonce"])
    keep, need_l1 = [], []
    for a in addrs:
        if n_now[a] <= n_old[a] or n_now[a] > maxn:
            continue
        (keep if n_now[a] >= minn else need_l1).append(a)
    print(f"  {len(keep)} pass on Base history; {len(need_l1)} need an Ethereum L1 history check…", file=sys.stderr)
    if need_l1:
        l1 = nonces_at(l1rpc, need_l1, hex(l1_block), batch)
        keep += [a for a in need_l1 if l1[a] >= int(el["l1_min_nonce"])]
    return sorted(keep)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--epoch", type=int, required=True)
    ap.add_argument("--block", type=int, required=True, help="snapshot block B (state is read at this block)")
    ap.add_argument("--rpc", required=True)
    ap.add_argument("--candidates")
    ap.add_argument("--scan", action="store_true", help="collect senders of blocks (B-window, B] via RPC")
    ap.add_argument("--window", type=int, default=None, help="default: config eligibility.window_blocks")
    ap.add_argument("--l1-rpc", default=None)
    ap.add_argument("--l1-block", type=int, default=None, help="Ethereum L1 block for rule (4)/(3); default: latest-5 (epoch 0: derived from B)")
    ap.add_argument("--batch", type=int, default=10, help="JSON-RPC batch size (public Base RPC allows 10)")
    ap.add_argument("--h0", type=int, default=None, help="epoch 0 only: the Bitcoin height that will seed genesis (written into the header, then committed)")
    ap.add_argument("--max0-wei", type=int, default=None, help="epoch 0 only: $100,000 of ETH in wei (genesis upper bound on Base+L1 balance; written into the header)")
    ap.add_argument("--token", default=None, help="epoch >= 2: token contract, to exclude recipients of closed epochs who never claimed (hasClaimed at B)")
    ap.add_argument("--min-wei", type=int, default=None, help="balance floor in wei ($100 of ETH at this snapshot's rate; default: config min_wei)")
    ap.add_argument("--ethusd-cents", type=int, default=None, help="ETH-USD rate used for the floor/cap, in cents (recorded in the header)")
    ap.add_argument("--data-dir", default=None, help="where earlier epochs' winners.json live (default: lottery/data)")
    ap.add_argument("--config", default=os.path.join(HERE, "config.json"))
    ap.add_argument("--out", default=None)
    ap.add_argument("--workers", type=int, default=8)
    a = ap.parse_args()
    cfg = json.load(open(a.config))
    el = cfg["eligibility"]
    rpc = Rpc(a.rpc, workers=a.workers)
    if a.window is None:
        a.window = int(el["window_blocks"])
    l1rpc = Rpc(a.l1_rpc or el["l1_rpc"], workers=a.workers)
    if a.l1_block:
        l1_block = a.l1_block
    elif a.epoch == 0:
        # genesis: L is not chosen — the highest Ethereum block whose timestamp <= timestamp(B)
        tb = int(rpc.call("eth_getBlockByNumber", [hex(a.block), False])["timestamp"], 16)
        l1_block = l1_block_at_or_before(l1rpc, tb)
        print(f"genesis: L = highest Ethereum block with timestamp <= {tb} → {l1_block}", file=sys.stderr)
    else:
        l1_block = int(l1rpc.call("eth_blockNumber", []), 16) - 5

    if a.candidates:
        cands = load_candidates(a.candidates)
    elif a.scan:
        cands = scan_senders(rpc, a.block - a.window + 1, a.block)
    else:
        sys.exit("give --candidates FILE or --scan")
    excl = sorted({x.lower() for x in el.get("exclude", [])})
    if a.epoch == 0 and a.h0 is None:
        sys.exit("epoch 0 needs --h0 (Bitcoin height that will seed genesis; ops/epoch.py computes tip + genesis_h0_offset_blocks)")
    if not excl:
        print("WARNING: eligibility.exclude is empty — fill it (token, vesting, pool, founder, operator) before a real snapshot", file=sys.stderr)
    cands -= set(excl)
    unbounded = (1 << 256) - 1
    min_wei = a.min_wei or int(el["min_wei"])
    if a.epoch == 0 and not a.max0_wei:
        sys.exit("epoch 0 needs --max0-wei ($100,000 of ETH in wei; ops/epoch.py computes it from the public spot price)")
    max_now = a.max0_wei if a.epoch == 0 else unbounded
    eligible = filter_eligible(rpc, cands, a.block, min_wei, max_now)
    age_block = a.block - int(el["age_window_blocks"])
    # (3) the balance floor must also have held one epoch earlier: capital sits through the epoch, not for a day
    print(f"balance floor at age block {age_block}…", file=sys.stderr)
    eligible = filter_eligible(rpc, eligible, age_block, min_wei, unbounded)
    if a.epoch == 0:
        # genesis: less than a bitcoin's worth in total — Base balance at B plus Ethereum L1 balance at L
        print(f"genesis: Base + Ethereum balance < {a.max0_wei/1e18:.4f} ETH ($100,000 at genesis), L1 at block {l1_block}…", file=sys.stderr)
        bl1 = balances_at(l1rpc, sorted(eligible), hex(l1_block), a.batch)
        bb = balances_at(rpc, sorted(eligible), hex(a.block), a.batch)
        eligible = [x for x in eligible if bb[x] + bl1[x] < a.max0_wei]
    eligible = filter_history(rpc, l1rpc, eligible, a.block, age_block, l1_block, el, a.batch)
    dropped_past = 0
    if el.get("exclude_past_recipients", True):  # every epoch, same rule; at genesis the set is simply empty
        past = past_recipients(a.data_dir or os.path.join(HERE, "data"), a.epoch)
        before = len(eligible)
        eligible = [x for x in eligible if x not in past]
        dropped_past = before - len(eligible)
        print(f"rule (5): {len(past)} addresses drawn in earlier epochs; {dropped_past} removed from this list", file=sys.stderr)

    out_dir = a.out or os.path.join(HERE, "data", f"epoch_{a.epoch}")
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "snapshot.csv")
    with open(path, "w", newline="\n") as f:
        f.write(HEADER_FMT.format(epoch=a.epoch, block=a.block, window=a.window, l1block=l1_block, min_wei=min_wei,
                                  ethusd=(f" ethusd={a.ethusd_cents}" if a.ethusd_cents else ""),
                                  h0=(f" h0={a.h0}" if a.epoch == 0 else ""), max0=(f" max0={a.max0_wei}" if a.epoch == 0 else ""),
                                  exclude=(",".join(excl) if excl else "none")))
        f.write("\n".join(eligible) + ("\n" if eligible else ""))
    digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
    meta = {
        "epoch": a.epoch, "block": a.block, "window": a.window, "age_block": age_block, "l1_block": l1_block, "rule": "v4",
        "h0": a.h0 if a.epoch == 0 else None, "max0_wei": a.max0_wei if a.epoch == 0 else None, "exclude": excl,
        "chain_id": el["chain_id"], "min_wei": min_wei, "ethusd_cents": a.ethusd_cents,
        "base_min_nonce": el["base_min_nonce"], "base_max_nonce": el["base_max_nonce"], "l1_min_nonce": el["l1_min_nonce"],
        "candidates": len(cands), "eligible": len(eligible), "dropped_past_recipients": dropped_past, "sha256": digest,
        "source": "scan" if a.scan else os.path.basename(a.candidates),
    }
    json.dump(meta, open(os.path.join(out_dir, "snapshot.meta.json"), "w"), indent=1)
    print(json.dumps(meta, indent=1))
    print(f"\ncommitSnapshot({a.epoch}, 0x{digest})")


if __name__ == "__main__":
    main()
