#!/usr/bin/env python3
"""Operator CLI for the Second Bitcoin halving draw.

  epoch.py status                       # where are we: BTC height, next H_k, contract state, what is due
  epoch.py snapshot K  [--scan | --candidates FILE] [--block B]
                                        # build data/epoch_K/snapshot.csv at Base block B (epoch 0: the contract's
                                        # genesisBlock, fixed; k >= 1: latest-5). The header is finalised at commit.
  epoch.py commit K    [--h0-offset N] [--force]
                                        # epoch 0: set H0 = Bitcoin tip + N (config 36) NOW, rewrite header, hash, send
                                        # commitSnapshot(0, hash, H0). k >= 1: refuses unless tip <= H_k - 36 (use --force for dry runs)
  epoch.py skip K                       # skipEpoch(K): tainted/impossible epoch → half burned, half moves to K+1, no vesting
  epoch.py draw K                       # fetch Bitcoin block hash at H_K, cap from the contract → winners.json
  epoch.py open K                       # send openEpoch(K, H_K, hash, root, count)
  epoch.py publish K                    # copy winners/proofs into site/data/ for the claim page

env: RPC_URL (Base), TOKEN (contract address), SIGNER (cast args, e.g. "--account 2btc-operator" or "--ledger"),
     SNAPSHOT_RPC_URL (optional: faster/archive endpoint for snapshot reads)
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LOTTERY = os.path.join(ROOT, "lottery")
sys.path.insert(0, LOTTERY)
from keccak import keccak256  # noqa: E402
from rpc import Rpc  # noqa: E402

MEMPOOL = os.environ.get("MEMPOOL_API", "https://mempool.space/api")
BLOCKS_UNIT = 2100
EPOCHS = 33


def h_of(genesis: int, k: int) -> int:
    """Bitcoin height seeding epoch k: H0 + 2,100·k(k+1)/2 (epoch lengths 2,100, 4,200, 6,300 …)."""
    return genesis + BLOCKS_UNIT * k * (k + 1) // 2


def spot(pair: str) -> float:
    return float(http_json(f"https://api.coinbase.com/v2/prices/{pair}/spot")["data"]["amount"])


def env(name, default=None):
    v = os.environ.get(name, default)
    if v is None:
        sys.exit(f"set {name}")
    return v


def cast(*args, signer=True):
    cmd = [os.path.expanduser("~/.foundry/bin/cast")] + list(args)
    if signer:
        cmd += env("SIGNER", "--account 2btc-operator").split()
    cmd += ["--rpc-url", env("RPC_URL")]
    print("$", " ".join(cmd))
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout.strip()


def http_json(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers={"user-agent": "2btc-ops/1.0"}), timeout=30) as r:
        return json.load(r)


def http_text(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers={"user-agent": "2btc-ops/1.0"}), timeout=30) as r:
        return r.read().decode().strip()


def btc_tip():
    return int(http_text(f"{MEMPOOL}/blocks/tip/height"))


def btc_block_hash(height):
    return http_text(f"{MEMPOOL}/block-height/{height}")


def btc_block_time(h):
    return http_json(f"{MEMPOOL}/block/{h}")["timestamp"]


def sel(sig):
    return "0x" + keccak256(sig.encode())[:4].hex()


def read_contract():
    rpc = Rpc(env("RPC_URL"))
    token = env("TOKEN")

    def call(sig, *args):
        data = sel(sig) + "".join(int(a).to_bytes(32, "big").hex() for a in args)
        return rpc.call("eth_call", [{"to": token, "data": data}, "latest"])

    st = {
        "epochsOpened": int(call("epochsOpened()"), 16),
        "genesisBtcHeight": int(call("genesisBtcHeight()"), 16),
        "finalized": int(call("finalized()"), 16) == 1,
        "scheduledRemaining": int(call("scheduledRemaining()"), 16),
        "poolBalance": int(call("poolBalance()"), 16),
        "poolSeeded": int(call("poolSeeded()"), 16) == 1,
        "genesisBlock": int(call("genesisBlock()"), 16),
        "epochsSkipped": int(call("epochsSkipped()"), 16),
    }
    prev = call("nextEpochCapPreview()")
    st["nextBase"], st["nextCarry"] = int(prev[2:66], 16), int(prev[66:130], 16)
    k = st["epochsOpened"]
    e = call("epochs(uint256)", k)
    words = [e[2:][i:i + 64] for i in range(0, len(e) - 2, 64)]
    st["nextCommit"] = {"snapshotHash": words[0], "commitTime": int(words[3], 16)}
    if k > 0:
        p = call("epochs(uint256)", k - 1)
        pw = [p[2:][i:i + 64] for i in range(0, len(p) - 2, 64)]
        st["lastOpenTime"] = int(pw[4], 16)
    return st


def cfg():
    return json.load(open(os.path.join(LOTTERY, "config.json")))


def data_dir(k):
    d = os.path.join(LOTTERY, "data", f"epoch_{k}")
    os.makedirs(d, exist_ok=True)
    return d


def cmd_status(a):
    st = read_contract()
    tip = btc_tip()
    k = st["epochsOpened"]
    print(json.dumps(st, indent=1))
    print(f"\nBitcoin tip height: {tip}")
    if st["finalized"]:
        print("contract finalized — nothing to do")
        return
    if k >= EPOCHS:
        print("all 33 epochs opened → finalize() once the last claim window has passed")
        return
    if k == 0:
        committed = int(st["nextCommit"]["snapshotHash"], 16) != 0
        if committed:
            print(f"GENESIS committed with H0={st['genesisBtcHeight']} ({st['genesisBtcHeight'] - tip:+d} blocks). When H0 has 6 confirmations: `draw 0` → `open 0`")
        else:
            print("next: GENESIS (epoch 0). Steps: `snapshot 0` (B = deployment block) → publish the list → `commit 0` (sets H0 = tip+36, fixes it on-chain) → wait for H0 + 6 conf → `draw 0` → `open 0`")
        return
    hk = h_of(st["genesisBtcHeight"], k)
    lead = int(cfg()["process"]["commit_lead_btc_blocks"])
    conf = int(cfg()["process"]["seed_confirmations"])
    eta_min = (hk - tip) * 10
    gap_ok = time.time() >= st.get("lastOpenTime", 0) + BLOCKS_UNIT * k * 600 * 4 / 5
    committed = int(st["nextCommit"]["snapshotHash"], 16) != 0
    print(f"next epoch k={k}: seed block H_k={hk} ({hk - tip:+d} blocks, ≈{eta_min/60:.1f} h; epoch {k-1} lasts {BLOCKS_UNIT*k:,} blocks)  committed={committed}  gap ok={gap_ok}")
    if not committed and hk - tip > lead:
        print(f"→ snapshot K + commit K must land while tip <= H_k - {lead} (≈{lead*10/60:.0f} h before, expected). Window left: {hk - tip - lead} blocks. Start the snapshot ≥ 12 h before H_k.")
    elif not committed and 0 < hk - tip <= lead:
        print(f"!! inside the {lead}-block lead: `commit K` will refuse (a commit here may read as late once miner timestamps are accounted for). Options: wait and `skip K` (half burned, half moves to K+1, no vesting), or --force and accept that verifiers may mark the epoch LATE/TAINTED.")
    elif committed and tip >= hk + conf:
        print(f"→ H_k has {tip - hk} confirmations (>= {conf}): `draw K` then `open K`")
    elif committed and tip >= hk:
        print(f"→ H_k mined; wait for {conf} confirmations ({conf - (tip - hk)} more) before `draw K`")
    elif not committed and tip >= hk:
        print("!! H_k already mined and no commit — the seed is known; a commit now cannot be trusted. Document it publicly; the contract offers no alternative seed.")


def cmd_snapshot(a):
    # reads can use a different (faster / archive) endpoint than the one we send transactions to
    read_rpc = os.environ.get("SNAPSHOT_RPC_URL", env("RPC_URL"))
    rpc = Rpc(read_rpc)
    if a.k == 0:
        block = read_contract()["genesisBlock"]  # B_0 is the deployment block — not chosen by the operator
        if a.block and a.block != block:
            if os.environ.get("DRYRUN"):
                print(f"DRYRUN: using block {a.block} instead of the genesis block {block} (verify will flag this)")
                block = a.block
            else:
                sys.exit(f"epoch 0 snapshot block is fixed to the genesis block {block}")
        print(f"genesis: snapshot block B = {block}")
    else:
        block = a.block or int(rpc.call("eth_blockNumber", []), 16) - 5
    cmd = [sys.executable, os.path.join(LOTTERY, "snapshot.py"), "--epoch", str(a.k), "--block", str(block),
           "--rpc", read_rpc, "--out", data_dir(a.k), "--workers", str(a.workers)]
    # USD thresholds at this snapshot's public rate: floor $100 of ETH (every epoch); genesis cap $100,000 of ETH
    c = cfg()["eligibility"]
    eth = spot("ETH-USD")
    min_wei = int(c["min_usd"] / eth * 10**18)
    cmd += ["--min-wei", str(min_wei), "--ethusd-cents", str(int(round(eth * 100)))]
    print(f"rate: ETH ${eth:,.2f} (Coinbase spot now) → floor ${c['min_usd']} = {min_wei/1e18:.5f} ETH")
    if a.k == 0:
        cmd += ["--h0", "0"]  # placeholder; the real H0 is written into the header at commit time
        max0 = a.max0_wei or int(c["genesis_cap_usd"] / eth * 10**18)
        print(f"genesis cap: ${c['genesis_cap_usd']:,} = {max0/1e18:.4f} ETH → max0={max0} wei")
        cmd += ["--max0-wei", str(max0)]
    cmd += ["--candidates", a.candidates] if a.candidates else ["--scan"]
    if a.k >= 2:
        cmd += ["--token", env("TOKEN"), "--data-dir", os.path.join(LOTTERY, "data")]
    if a.window:
        cmd += ["--window", str(a.window)]
    subprocess.run(cmd, check=True)


def _rewrite_header(path, **kv):
    """Replace key=value pairs in the snapshot header line; returns the new sha256."""
    import hashlib
    raw = open(path, "rb").read()
    first, rest = raw.split(b"\n", 1)
    parts = first.decode().split()
    for i, p in enumerate(parts):
        k = p.split("=", 1)[0]
        if k in kv:
            parts[i] = f"{k}={kv[k]}"
    new = (" ".join(parts) + "\n").encode() + rest
    open(path, "wb").write(new)
    return hashlib.sha256(new).hexdigest()


def cmd_commit(a):
    d = data_dir(a.k)
    meta = json.load(open(os.path.join(d, "snapshot.meta.json")))
    st = read_contract()
    tip = btc_tip()
    proc = cfg()["process"]
    lead = int(proc["commit_lead_btc_blocks"])
    if a.k == 0:
        off = a.h0_offset if a.h0_offset is not None else int(proc["genesis_h0_offset_blocks"])
        h0 = tip + off
        sha = _rewrite_header(os.path.join(d, "snapshot.csv"), h0=h0)
        meta["h0"], meta["sha256"] = h0, sha
        json.dump(meta, open(os.path.join(d, "snapshot.meta.json"), "w"), indent=1)
        print(f"GENESIS: H0 = Bitcoin tip {tip} + {off} = {h0}; header rewritten, sha256={sha}")
    else:
        h0 = 0
        hk = h_of(st["genesisBtcHeight"], a.k)
        if hk - tip < lead and not a.force:
            sys.exit(f"refusing: Bitcoin tip {tip} is within {lead} blocks of H_k={hk} ({hk - tip} left). "
                     f"Wait for the next epoch and `skip {a.k}`, or pass --force (dry runs only).")
    # B-age guard (verifiers FAIL if timestamp(B) is >12 h before the commit): warn well before that
    try:
        read_rpc = os.environ.get("SNAPSHOT_RPC_URL", env("RPC_URL"))
        bts = int(Rpc(read_rpc).call("eth_getBlockByNumber", [hex(int(meta["block"])), False])["timestamp"], 16)
        age_h = (int(__import__("time").time()) - bts) / 3600
        if age_h > 10:
            print(f"!! snapshot block B is {age_h:.1f} h old; verifiers FAIL beyond 12 h. Re-snapshot before committing." + ("" if a.force else " (use --force to override)"))
            if not a.force:
                sys.exit(1)
    except SystemExit:
        raise
    except Exception:
        pass
    print(f"committing epoch {a.k} snapshot sha256={meta['sha256']} (block {meta['block']}, {meta['eligible']} eligible); BTC tip {tip}")
    print("The committed bytes must be public BEFORE this transaction lands. The tool now waits for you to push them.")
    print(f"  → run in another shell:  git add lottery/data/epoch_{a.k} && git commit -m 'epoch {a.k} list' && git push")
    if sys.stdin.isatty():
        input("  press Enter once the snapshot is pushed/pinned to broadcast the commit… ")
    out = cast("send", env("TOKEN"), "commitSnapshot(uint256,bytes32,uint64)", str(a.k), "0x" + meta["sha256"], str(h0))
    print(out.splitlines()[-1] if out else "")


def cmd_draw(a):
    st = read_contract()
    k = a.k
    assert k == st["epochsOpened"], f"next epoch to open is {st['epochsOpened']}"
    h = h_of(st["genesisBtcHeight"], k)  # H0 was fixed on-chain at the genesis commit
    assert h > 0, "genesis not committed yet"
    tip = btc_tip()
    conf = int(cfg()["process"]["seed_confirmations"])
    assert tip >= h, f"Bitcoin height {h} not mined yet (tip {tip})"
    if tip - h < conf:
        print(f"!! only {tip - h} confirmations on H_k (policy: {conf}); proceed only for dry runs")
    bh = btc_block_hash(h)
    try:
        bh2 = http_text(f"https://blockstream.info/api/block-height/{h}")
        if bh2.lower() != bh.lower():
            sys.exit(f"!! explorers disagree on block {h}: mempool.space {bh} vs blockstream {bh2} — check a Bitcoin node")
    except Exception as ex:  # noqa: BLE001
        print(f"(second explorer unavailable: {str(ex)[:60]}; confirm the hash with a Bitcoin node)")
    bt = btc_block_time(bh)
    ct = st["nextCommit"]["commitTime"]
    ok_s = int(cfg()["process"]["commit_lead_seconds_ok"]); min_s = int(cfg()["process"]["commit_lead_seconds_min"])
    lead_s = bt - ct
    tier = "OK" if lead_s >= ok_s else ("LATE (warning)" if lead_s >= min_s else ("TAINTED — consider `skip`" if lead_s > 0 else "INVALID (commit after the block)"))
    print(f"epoch {k}: H_k={h} hash={bh} block_time={bt} commitTime={ct} lead={lead_s}s → {tier}")
    cap = st["nextBase"] + st["nextCarry"]
    d = data_dir(k)
    subprocess.run([sys.executable, os.path.join(LOTTERY, "run_draw.py"), "--epoch", str(k), "--btc-height", str(h),
                    "--btc-hash", "0x" + bh, "--cap-units", str(cap), "--snapshot", os.path.join(d, "snapshot.csv")], check=True)


def cmd_open(a):
    w = json.load(open(os.path.join(data_dir(a.k), "winners.json")))
    # the cap can move while epoch k-1's claim window is still open (epoch 1 especially): re-read it right before opening
    st = read_contract()
    cap_now = st["nextBase"] + st["nextCarry"]
    if cap_now != w["cap_units"]:
        sys.exit(f"cap changed since the draw ({w['cap_units']} → {cap_now}; a claim of the previous epoch landed in between). Re-run `draw {a.k}` then `open {a.k}` back to back.")
    out = cast("send", env("TOKEN"), "openEpoch(uint256,uint64,bytes32,bytes32,uint32)", str(a.k), str(w["btc_height"]),
               w["btc_hash"], w["root"], str(w["count"]))
    print(out.splitlines()[-1] if out else "")


def cmd_skip(a):
    st = read_contract()
    assert a.k == st["epochsOpened"], f"next epoch is {st['epochsOpened']}"
    print(f"skipping epoch {a.k}: half of its amount is burned, half moves to epoch {a.k + 1}; no vesting for this epoch. Publish the reason.")
    out = cast("send", env("TOKEN"), "skipEpoch(uint256)", str(a.k))
    print(out.splitlines()[-1] if out else "")


def cmd_publish(a):
    d = data_dir(a.k)
    site = os.path.join(ROOT, "site", "data")
    os.makedirs(site, exist_ok=True)
    for f in ("winners.json", "proofs.json", "snapshot.meta.json"):
        shutil.copy(os.path.join(d, f), os.path.join(site, f"epoch_{a.k}_{f}"))
    idx_path = os.path.join(site, "index.json")
    idx = json.load(open(idx_path)) if os.path.exists(idx_path) else {"epochs": []}
    if a.k not in idx["epochs"]:
        idx["epochs"].append(a.k)
    json.dump(idx, open(idx_path, "w"))
    print(f"published epoch {a.k} → site/data/ (snapshot.csv itself: publish via repo/IPFS, it can be large)")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    s = sub.add_parser("snapshot"); s.add_argument("k", type=int); s.add_argument("--block", type=int); s.add_argument("--candidates"); s.add_argument("--window", type=int); s.add_argument("--workers", type=int, default=8); s.add_argument("--max0-wei", type=int, default=None, help="epoch 0: override the $100,000-of-ETH cap (wei); default: Coinbase spot ETH-USD")
    s = sub.add_parser("commit"); s.add_argument("k", type=int); s.add_argument("--h0-offset", type=int, default=None, help="epoch 0: H0 = Bitcoin tip + offset (config 36); negative only for dry runs"); s.add_argument("--force", action="store_true")
    s = sub.add_parser("skip"); s.add_argument("k", type=int)
    s = sub.add_parser("draw"); s.add_argument("k", type=int)
    s = sub.add_parser("open"); s.add_argument("k", type=int)
    s = sub.add_parser("publish"); s.add_argument("k", type=int)
    a = ap.parse_args()
    {"status": cmd_status, "snapshot": cmd_snapshot, "commit": cmd_commit, "draw": cmd_draw, "open": cmd_open, "publish": cmd_publish, "skip": cmd_skip}[a.cmd](a)


if __name__ == "__main__":
    main()
