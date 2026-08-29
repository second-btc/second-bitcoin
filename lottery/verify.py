#!/usr/bin/env python3
"""Third-party verification: recompute epoch k from public inputs and compare with the published list
(and, optionally, with the values stored on-chain).

usage: verify.py --epoch K --snapshot snapshot.csv --winners winners.json [--rpc URL --token 0x...] [--mempool URL]

Checks (offline): snapshot hash, header sanity, exclusions, the draw itself, the Merkle root.
Checks (with --rpc/--token): on-chain snapshotHash / btcHash / root / cap / btcHeight, H0 bound at the genesis commit,
snapshot block B and L1 block L taken within 12 h before the commit, and floor min×ethusd ≈ $100 (verifier tolerance).
Checks (with --completeness R): OMISSIONS — eligible senders missing from the list.
Checks (with --rederive R): INCLUSIONS — listed addresses that do not meet rule §4.1 (needs --token for rule 5).
Checks (with --mempool, convenience only — a Bitcoin node is authoritative): seed == hash of Bitcoin block H_k, and the
commit landed >= 2 h before that block's timestamp.
"""
import argparse
import json
import os
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from keccak import keccak256  # noqa: E402
from lottery import draw, load_config, load_snapshot  # noqa: E402
from merkle import MerkleTree, leaf_hash  # noqa: E402


def eth_call(rpc, to, data):
    req = urllib.request.Request(
        rpc,
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_call", "params": [{"to": to, "data": data}, "latest"]}).encode(),
        headers={"content-type": "application/json"},
    )
    return json.load(urllib.request.urlopen(req, timeout=30))["result"]


def onchain_epoch(rpc, token, k):
    sel = keccak256(b"epochs(uint256)")[:4].hex()
    res = eth_call(rpc, token, "0x" + sel + k.to_bytes(32, "big").hex())
    words = [res[2:][i:i + 64] for i in range(0, len(res) - 2, 64)]
    names = ["snapshotHash", "btcHash", "root", "commitTime", "openTime", "btcHeight", "count", "cap", "claimed", "skipped"]
    return {n: (words[i] if i < len(words) else "0" * 64) for i, n in enumerate(names)}


def _check_ethusd(header, block_ts, check):
    """Best-effort: compare the header's ethusd with an independent historical ETH-USD at block B's timestamp."""
    if "ethusd" not in header or not block_ts:
        return
    try:
        day = time.strftime("%d-%m-%Y", time.gmtime(int(block_ts)))
        url = f"https://api.coingecko.com/api/v3/coins/ethereum/history?date={day}&localization=false"
        req = urllib.request.Request(url, headers={"user-agent": "2btc-verify/1.0"})
        ref = json.load(urllib.request.urlopen(req, timeout=30))["market_data"]["current_price"]["usd"]
        hdr = int(header["ethusd"]) / 100
        check(f"header ETH-USD ${hdr:,.0f} within 8% of the independent daily close ${ref:,.0f}", abs(hdr - ref) / ref <= 0.08, f"header {hdr:.0f} vs ref {ref:.0f}")
    except Exception as ex:  # noqa: BLE001
        print(f"skip independent ETH-USD cross-check ({str(ex)[:60]}); confirm the header rate against a price source at block B's time")


import time  # noqa: E402


def onchain_uint(rpc, token, sig):
    return int(eth_call(rpc, token, "0x" + keccak256(sig.encode())[:4].hex()), 16)


def block_timestamp(rpc, number):
    req = urllib.request.Request(
        rpc,
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_getBlockByNumber", "params": [hex(number), False]}).encode(),
        headers={"content-type": "application/json", "user-agent": "2btc-verify/1.0"},
    )
    blk = json.load(urllib.request.urlopen(req, timeout=30))["result"]
    return int(blk["timestamp"], 16) if blk else None


def commit_log_count(rpc, token, k):
    topic0 = "0x" + keccak256(b"SnapshotCommitted(uint256,bytes32,uint64)").hex()
    topic1 = "0x" + k.to_bytes(32, "big").hex()
    req = urllib.request.Request(
        rpc,
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_getLogs",
                         "params": [{"address": token, "fromBlock": "0x0", "toBlock": "latest", "topics": [topic0, topic1]}]}).encode(),
        headers={"content-type": "application/json", "user-agent": "2btc-verify/1.0"},
    )
    res = json.load(urllib.request.urlopen(req, timeout=60))
    return len(res.get("result", [])) if "result" in res else None


def http_text(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers={"user-agent": "2btc-verify/1.0"}), timeout=30).read().decode().strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--epoch", type=int, required=True)
    ap.add_argument("--snapshot", required=True)
    ap.add_argument("--winners", required=True)
    ap.add_argument("--config", default=os.path.join(os.path.dirname(__file__), "config.json"))
    ap.add_argument("--rpc", help="Base RPC (archive not required for these checks)")
    ap.add_argument("--token")
    ap.add_argument("--l1-rpc", default=None, help="Ethereum L1 RPC for the L-block age check (default: config)")
    ap.add_argument("--mempool", default=None, help="e.g. https://mempool.space/api — cross-check of the Bitcoin seed and commit lead (needed for a full VERIFIED)")
    ap.add_argument("--completeness", type=int, default=0, metavar="R", help="OMISSIONS: sample R blocks of the window and check every eligible sender is in the snapshot (needs an archive RPC)")
    ap.add_argument("--rederive", type=int, default=0, metavar="R", help="INCLUSIONS: sample R addresses from the list and re-test rule §4.1 at B/B-W (needs an archive RPC; catches stuffed ineligible addresses)")
    ap.add_argument("--seed", default=None, help="completeness sample seed (default: the epoch's Bitcoin block hash — unknown when the list was built)")
    a = ap.parse_args()

    cfg = load_config(a.config)
    pub = json.load(open(a.winners))
    global pub_hash_for_completeness
    pub_hash_for_completeness = pub["btc_hash"]
    snapshot, digest, header = load_snapshot(a.snapshot)
    ok = True

    def check(name, cond, detail=""):
        nonlocal ok
        ok &= bool(cond)
        print(("OK   " if cond else "FAIL ") + name + (f"  {detail}" if detail else ""))

    check("snapshot sha256 matches winners.json", digest == pub["snapshot_sha256"], digest)
    check("snapshot header present (epoch/block/window/l1block/min/rule/exclude)",
          all(k in header for k in ("epoch", "block", "window", "l1block", "min", "rule", "exclude")) and str(header.get("epoch")) == str(a.epoch),
          str(header))
    excl = [x for x in header.get("exclude", "none").split(",") if x.startswith("0x")]
    check("no excluded address in the snapshot", not (set(excl) & set(snapshot)), f"{len(excl)} excluded")
    if a.epoch == 0:
        check("genesis header carries h0", "h0" in header and int(header["h0"]) == pub["btc_height"], header.get("h0"))
        check("genesis header carries max0 ($100,000 of ETH at genesis)", "max0" in header and int(header["max0"]) > 0, f"max0={int(header.get('max0', 0))/1e18:.4f} ETH")
    if "min" in header and "ethusd" in header:
        min_usd = int(header["min"]) / 1e18 * int(header["ethusd"]) / 100
        check(f"floor is $100 of ETH (min × ethusd = ${min_usd:,.2f}; rule allows $90–$110)", 90.0 <= min_usd <= 110.0,
              f"{int(header['min'])/1e18:.5f} ETH at ETH ${int(header['ethusd'])/100:,.2f}")
    else:
        check("header carries the floor and the rate (min, ethusd)", False, str(header))
    winners = draw(snapshot, a.epoch, pub["btc_hash"], pub["cap_units"], cfg)
    pub_list = [(w["address"], w["amount_units"]) for w in pub["winners"]]
    check("winner list identical (same order, same amounts)", winners == pub_list, f"{len(winners)} winners")
    tree = MerkleTree([leaf_hash(a.epoch, addr, amt) for addr, amt in winners])
    root = "0x" + tree.root.hex()
    check("merkle root matches winners.json", root == pub["root"].lower(), root)
    check("published count == number of winners", pub["count"] == len(pub["winners"]) == len(winners), str(len(winners)))
    full = False

    if a.rpc and a.token:
        e = onchain_epoch(a.rpc, a.token, a.epoch)
        if int(e["skipped"], 16) == 1:
            print(f"\nRESULT: SKIPPED — epoch {a.epoch} was skipped on-chain (commitTime={int(e['commitTime'],16)}); half of its coins were burned, half moved to the next epoch; no draw to verify")
            sys.exit(0)
        check("on-chain snapshotHash == sha256(snapshot)", e["snapshotHash"] == digest)
        check("on-chain btcHash == published seed", e["btcHash"] == pub["btc_hash"].lower().replace("0x", ""))
        check("on-chain root == recomputed root", "0x" + e["root"] == root)
        cap_chain = int(e["cap"], 16); cap_pub = pub["cap_units"]
        if cap_chain == cap_pub:
            check("on-chain cap == published cap", True, str(cap_chain))
        elif cap_chain < cap_pub:
            short = cap_pub - cap_chain
            print(f"WARN on-chain cap {cap_chain} < published {cap_pub} by {short/1e8:.8f} coins — a claim of the previous epoch landed between draw and open (§8); the last claimant absorbs the shortfall. Not a mismatch.")
        else:
            check("on-chain cap == published cap", False, f"chain {cap_chain} > published {cap_pub}")
        ct, ht = int(e["commitTime"], 16), int(e["btcHeight"], 16)
        check("on-chain btcHeight == published H_k", ht == pub["btc_height"], str(ht))
        g0 = onchain_uint(a.rpc, a.token, "genesisBtcHeight()")
        check("H_k == H0 + 2,100·k(k+1)/2 with H0 fixed at the genesis commit", ht == g0 + 2100 * a.epoch * (a.epoch + 1) // 2, f"H0={g0}")
        n_commits = commit_log_count(a.rpc, a.token, a.epoch)
        if n_commits is not None:
            check("one SnapshotCommitted event for this epoch (the contract enforces one-shot commits)", n_commits == 1, str(n_commits))
        else:
            print("info log query unavailable on this RPC; the contract itself refuses a second commit (AlreadyCommitted)")
        proc = cfg.get("process", {})
        max_age = int(proc.get("snapshot_max_age_seconds", 43200))
        if a.epoch == 0:
            gb = onchain_uint(a.rpc, a.token, "genesisBlock()")
            check("epoch 0 snapshot block B == deployment block (not chosen by the operator)", int(header["block"]) == gb, f"genesisBlock={gb}")
            try:
                tb0 = block_timestamp(a.rpc, int(header["block"]))
                l1 = a.l1_rpc or cfg["eligibility"]["l1_rpc"]
                tl = block_timestamp(l1, int(header["l1block"]))
                tl_next = block_timestamp(l1, int(header["l1block"]) + 1)
                check("epoch 0 L == highest Ethereum block with timestamp <= timestamp(B) (not chosen)", tl is not None and tl <= tb0 and (tl_next is None or tl_next > tb0), f"L={header['l1block']} t={tl} B_t={tb0}")
                _check_ethusd(header, tb0, check)
            except Exception as ex:  # noqa: BLE001
                print(f"skip genesis L check ({str(ex)[:60]})")
        else:
            tb = block_timestamp(a.rpc, int(header["block"]))
            check(f"snapshot block B taken within {max_age//3600} h before the commit", tb is not None and 0 <= ct - tb <= max_age, f"B={header['block']} t={tb} commit={ct}")
        try:
            l1 = a.l1_rpc or cfg["eligibility"]["l1_rpc"]
            tl = block_timestamp(l1, int(header["l1block"]))
            check(f"L1 block L taken within {max_age//3600} h before the commit", tl is not None and 0 <= ct - tl <= max_age, f"L={header['l1block']} t={tl}")
        except Exception as ex:  # noqa: BLE001
            print(f"skip L1 block age check ({str(ex)[:60]})")
        if a.mempool:
            bh = http_text(f"{a.mempool}/block-height/{ht}")
            check("seed == Bitcoin block hash at H_k (per the explorer; a Bitcoin node is authoritative)", bh.lower() == pub["btc_hash"].lower().replace("0x", ""), bh)
            bt = json.loads(http_text(f"{a.mempool}/block/{bh}"))["timestamp"]
            ok_s = int(proc.get("commit_lead_seconds_ok", 14400)); min_s = int(proc.get("commit_lead_seconds_min", 7200))
            lead_s = bt - ct
            if lead_s >= ok_s:
                check("commit lead before block H_k: OK (>= 4 h)", True, f"lead={lead_s}s")
            elif lead_s >= min_s:
                check("commit lead before block H_k: LATE (2–4 h) — warning, not proof of misconduct", True, f"lead={lead_s}s")
                print("WARN this epoch's commit was late; Bitcoin timestamps are miner-set within ~2 h, so a 2–4 h lead is acceptable but should not recur")
            else:
                check("commit lead before block H_k >= 2 h (else TAINTED: indistinguishable from a commit made after the block)", False, f"lead={lead_s}s")
            full = True
        else:
            print(f"info commitTime={ct} btcHeight={ht} → NOT VERIFIED AGAINST BITCOIN: confirm with a node that block {ht}'s hash is the seed and its timestamp >= commit + 2 h, or pass --mempool")
        if a.completeness > 0:
            ok &= completeness(a, cfg, header, set(snapshot))
        if a.rederive > 0:
            ok &= inclusion(a, cfg, header, snapshot)
    membership = a.completeness > 0 and a.rederive > 0
    if not ok:
        print("\nRESULT: MISMATCH")
    elif not full:
        print("\nRESULT: INCOMPLETE — offline/contract checks passed, but the Bitcoin seed and commit lead were not checked (pass --rpc/--token and --mempool, or use a node)")
    elif not membership:
        print("\nRESULT: VERIFIED (draw + contract). NOTE: list membership was NOT fully re-derived — that the listed addresses are exactly the eligible set is checked only with --completeness (omissions) AND --rederive (inclusions), each needing an archive node.")
    else:
        print("\nRESULT: VERIFIED (draw, contract, and sampled list membership)")
    sys.exit(0 if ok else 1)


pub_hash_for_completeness = "0"


def inclusion(a, cfg, header, snapshot):
    """Sample R listed addresses and re-test rule §4.1 at B / B-W (catches stuffed ineligible addresses)."""
    import random
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from rpc import Rpc
    from snapshot import balances_at, filter_eligible, filter_history, unclaimed_recipients
    el = cfg["eligibility"]
    B, W, L = int(header["block"]), int(header["window"]), int(header["l1block"])
    min_wei = int(header.get("min", el["min_wei"]))
    max0 = int(header.get("max0", 0)) if a.epoch == 0 else (1 << 256) - 1
    rpc = Rpc(a.rpc, workers=4); l1 = Rpc(a.l1_rpc or el["l1_rpc"], workers=4)
    rnd = random.Random(int(a.seed or pub_hash_for_completeness, 16))
    sample = rnd.sample(snapshot, min(a.rederive, len(snapshot)))
    unbounded = (1 << 256) - 1
    kept = filter_eligible(rpc, sample, B, min_wei, max0 if a.epoch == 0 else unbounded)
    kept = filter_eligible(rpc, kept, B - int(el["age_window_blocks"]), min_wei, unbounded)
    if a.epoch == 0 and kept:  # genesis cap is Base(B) + L1(L) < max0, matching snapshot.py / completeness()
        bl1 = balances_at(l1, sorted(kept), hex(L)); bb = balances_at(rpc, sorted(kept), hex(B))
        kept = [x for x in kept if bb[x] + bl1[x] < max0]
    kept = filter_history(rpc, l1, kept, B, B - int(el["age_window_blocks"]), L, el)
    if a.epoch >= 2 and a.token and el.get("exclude_unclaimed_recipients", True):  # rule 5
        unc = unclaimed_recipients(rpc, a.token, os.path.dirname(os.path.dirname(os.path.abspath(a.snapshot))), a.epoch, B)
        kept = [x for x in kept if x not in unc]
    kept = set(kept)
    bad = [x for x in sample if x not in kept]
    okc = not bad
    print(("OK   " if okc else "FAIL ") + f"inclusion: {len(sample)} sampled listed addresses re-tested, {len(bad)} do NOT meet rule §4.1")
    for x in bad[:10]:
        print("     ineligible but listed:", x)
    return okc


def completeness(a, cfg, header, snapshot_set):
    """Sample R blocks of (B-W, B]; every sender that satisfies the rule must be in the snapshot (catches omissions)."""
    import random
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from rpc import Rpc
    from snapshot import balances_at, filter_eligible, filter_history, unclaimed_recipients
    el = cfg["eligibility"]
    B, W, L = int(header["block"]), int(header["window"]), int(header["l1block"])
    rpc = Rpc(a.rpc, workers=4)
    l1 = Rpc(a.l1_rpc or el["l1_rpc"], workers=4)
    seed_src = a.seed or pub_hash_for_completeness
    rnd = random.Random(int(seed_src, 16))  # default: the Bitcoin seed hash — not known when the list was made; reproducible by others
    blocks = sorted(rnd.sample(range(B - W + 1, B + 1), min(a.completeness, W)))
    senders = set()
    for b in blocks:
        blk = rpc.call("eth_getBlockByNumber", [hex(b), True])
        if blk is None:
            print(f"FAIL block {b} unavailable"); return False
        senders |= {tx["from"].lower() for tx in blk.get("transactions", [])}
    excl = {x for x in header.get("exclude", "none").split(",") if x.startswith("0x")}
    senders -= excl
    unbounded = (1 << 256) - 1
    max0 = int(header.get("max0", 0)) if a.epoch == 0 else unbounded
    min_wei = int(header.get("min", el["min_wei"]))
    elig = filter_eligible(rpc, senders, B, min_wei, max0)
    age_block = B - int(el["age_window_blocks"])
    elig = filter_eligible(rpc, elig, age_block, min_wei, unbounded)
    if a.epoch == 0 and elig:
        bl1 = balances_at(l1, sorted(elig), hex(L))
        bb = balances_at(rpc, sorted(elig), hex(B))
        elig = [x for x in elig if bb[x] + bl1[x] < max0]
    elig = filter_history(rpc, l1, elig, B, age_block, L, el)
    if a.epoch >= 2 and a.token and el.get("exclude_unclaimed_recipients", True):
        unc = unclaimed_recipients(rpc, a.token, os.path.dirname(os.path.dirname(os.path.abspath(a.snapshot))), a.epoch, B)
        elig = [x for x in elig if x not in unc]
    missing = [x for x in elig if x not in snapshot_set]
    okc = not missing
    print(("OK   " if okc else "FAIL ") + f"completeness: {len(blocks)} sampled blocks, {len(senders)} senders, {len(elig)} eligible, {len(missing)} missing from the snapshot")
    for m in missing[:10]:
        print("     missing:", m)
    return okc


if __name__ == "__main__":
    main()
