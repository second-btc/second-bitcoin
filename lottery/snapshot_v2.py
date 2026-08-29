#!/usr/bin/env python3
"""Second Bitcoin v2 — canonical eligibility snapshot builder + verifier.

Implements lottery/ELIGIBILITY_SPEC_V2.md exactly. Build produces the eligible list, the committed header
(with setRoot, N and a self-binding header hash), and feeds build_v2_proofs.py. Verify RE-DERIVES the block
anchors from T_B and re-runs the SAME predicate code, then diffs — so build and verify are byte-identical by
construction (the reproducibility guarantee).

Consensus reads only (eth_getBalance / eth_getTransactionCount / eth_getCode) at fixed FINALIZED historical
blocks, on BOTH Base and Ethereum L1 archive nodes. A consensus read that errors/goes missing ABORTS the run —
it must never silently resolve to a default (that would corrupt the list non-deterministically).

Usage:
  BASE_RPC_URL=... ETH_RPC_URL=... python3 snapshot_v2.py build --t-b <unix_ts> \
      --exclude 0xToken,0xVesting,0xPool,0xFounder --out data_v2
  BASE_RPC_URL=... ETH_RPC_URL=... python3 snapshot_v2.py verify --header data_v2/header.json \
      --candidates data_v2/candidates.txt --expect-root 0x.. --expect-n 12345
"""
import argparse
import json
import os
import re
import sqlite3
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from keccak import keccak256  # noqa: E402
from build_v2_proofs import leaf_v2  # noqa: E402
from merkle import MerkleTree  # noqa: E402

RULE_ID = "2btc-v2-oneshot"
FLOOR_WEI = 100_000_000_000_000_000        # 0.1 ETH, inclusive
CAP_WEI = 40_000_000_000_000_000_000       # 40 ETH, exclusive
MIN_AGE_S = 31_536_000                      # 365 days
MIN_TXS = 20
MAX_TXS = 20_000
TWO_WEEKS_S = 1_209_600                     # 14 days
EIP7702_PREFIX = "0xef0100"                 # delegation designator; total code length 23 bytes = 46 hex
ADDR_RE = re.compile(r"^0x[0-9a-f]{40}$")


# ------------------------------------------------------------------ JSON-RPC (strict, batched)
class RPC:
    def __init__(self, url, batch=40, attempts=None):
        self.url = url
        self.batch = batch
        # standalone: retry hard (12/10). Inside MultiRPC: fail FAST (the wrapper rotates endpoints).
        self.post_attempts = attempts or 12
        self.chunk_attempts = attempts or 10
        self._id = 0

    def _post(self, body):
        req = urllib.request.Request(
            self.url, data=json.dumps(body).encode(),
            headers={"content-type": "application/json",
                     # several public gateways WAF-block the default python-urllib agent
                     "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_4) snapshot/2.0"},
        )
        last = self.post_attempts - 1
        for attempt in range(self.post_attempts):
            try:
                with urllib.request.urlopen(req, timeout=90) as r:
                    return json.load(r)
            except urllib.error.HTTPError as e:
                if e.code in (429, 503) and attempt < last:  # rate limit / capacity → back off and retry
                    time.sleep(min(0.4 * 2 ** attempt, 20))
                    continue
                if attempt == last:
                    raise
                time.sleep(1 + attempt)
            except Exception:  # noqa: BLE001
                if attempt == last:
                    raise
                time.sleep(1 + attempt)

    def call(self, method, params):
        self._id += 1
        out = self._post({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params})
        if "error" in out:
            raise RuntimeError(f"{method} {params}: {out['error']}")
        return out["result"]

    TRANSIENT = {429, 503, -32005}  # rate-limit / capacity → retry; anything else is fatal (abort loudly)

    def batch_call(self, calls):
        """Aligned results. TRANSIENT per-item errors (rate limit / capacity) retry the whole chunk with
        backoff; any OTHER error, or a missing/null result, aborts — a consensus read must never silently
        default (that is the list-corruption vector)."""
        results = [None] * len(calls)
        for start in range(0, len(calls), self.batch):
            chunk = calls[start:start + self.batch]
            body = [{"jsonrpc": "2.0", "id": start + i, "method": m, "params": p} for i, (m, p) in enumerate(chunk)]
            for attempt in range(self.chunk_attempts):
                out = self._post(body)
                if not isinstance(out, list):
                    raise RuntimeError(f"batch response not a list: {str(out)[:200]}")
                if any("error" in o and o["error"].get("code") in self.TRANSIENT for o in out):
                    if attempt == self.chunk_attempts - 1:
                        raise RuntimeError("batch: transient errors persisted after retries")
                    time.sleep(min(0.5 * 2 ** attempt, 20))
                    continue
                by_id = {}
                for o in out:
                    oid = o.get("id")
                    if isinstance(oid, str) and oid.isdigit():
                        oid = int(oid)
                    if "error" in o:
                        raise RuntimeError(f"batch item {oid} error: {o['error']}")
                    by_id[oid] = o.get("result")
                for i in range(len(chunk)):
                    idx = start + i
                    if idx not in by_id or by_id[idx] is None:
                        raise RuntimeError(f"batch item {idx} missing/null ({chunk[i][0]} {chunk[i][1]})")
                    results[idx] = by_id[idx]
                break
        return results


class MultiRPC:
    """Same interface as RPC, spread over several endpoints. Consensus reads at fixed finalized blocks
    return the SAME value from any honest node, so endpoint choice cannot change results — rotation only
    buys throughput and survives per-provider rate bans. Strictness is preserved: a chunk that fails on
    EVERY endpoint repeatedly still aborts the run (no silent defaults)."""

    def __init__(self, urls, batch=40):
        self.eps = [RPC(u, batch=batch, attempts=2) for u in urls]
        self.batch = batch
        self._i = 0
        self._lock = threading.Lock()
        self._cool = [0.0] * len(self.eps)   # rest-until unix ts per endpoint
        self._fails = [0] * len(self.eps)

    def _pick(self):
        with self._lock:
            now = time.time()
            n = len(self.eps)
            for k in range(n):
                j = (self._i + k) % n
                if self._cool[j] <= now:
                    self._i = j + 1
                    return j, 0.0
            j = min(range(n), key=lambda x: self._cool[x])
            self._i = j + 1
            return j, max(0.0, self._cool[j] - now)

    def _rest(self, j):
        with self._lock:
            self._fails[j] += 1
            self._cool[j] = time.time() + min(8 * 2 ** min(self._fails[j] - 1, 5), 240)

    def _ok(self, j):
        with self._lock:
            self._fails[j] = 0

    def _run(self, fn, what):
        last = None
        for round_ in range(8 * len(self.eps)):
            j, wait = self._pick()
            if wait:
                time.sleep(min(wait, 20))
            try:
                out = fn(self.eps[j])
                self._ok(j)
                return out
            except Exception as e:  # noqa: BLE001 — includes strict non-transient: try other endpoints first
                self._rest(j)
                last = e
        raise RuntimeError(f"all endpoints failed for {what}: {last}")

    def call(self, method, params):
        return self._run(lambda ep: ep.call(method, params), method)

    def batch_call(self, calls):
        out = [None] * len(calls)
        for start in range(0, len(calls), self.batch):
            chunk = calls[start:start + self.batch]
            res = self._run(lambda ep: ep.batch_call(chunk), f"chunk@{start}")
            out[start:start + len(chunk)] = res
        return out


def make_rpc(env_single, env_multi):
    urls = [u.strip() for u in os.environ.get(env_multi, "").split(",") if u.strip()]
    batch = int(os.environ.get("RPC_BATCH", "40"))
    if urls:
        return MultiRPC(urls, batch=batch)
    return RPC(os.environ[env_single], batch=batch)


def to_int(x):
    return int(x, 16)  # x is a validated hex string from a strict read; raises on anything else


def hexblk(n):
    return hex(n)


# ------------------------------------------------------------------ block anchors (§1, finalized head)
def finalized_number(rpc):
    b = rpc.call("eth_getBlockByNumber", ["finalized", False])
    if not b:
        raise RuntimeError("no finalized block")
    return to_int(b["number"])


def block_ts(rpc, n):
    return to_int(rpc.call("eth_getBlockByNumber", [hexblk(n), False])["timestamp"])


def block_at_or_after_ts(rpc, ts):
    """First block with timestamp >= ts, within the finalized head."""
    tip = finalized_number(rpc)
    if block_ts(rpc, tip) < ts:
        raise RuntimeError(f"finalized tip ts < target {ts}; wait for finality")
    lo, hi = 0, tip
    while lo < hi:
        mid = (lo + hi) // 2
        if block_ts(rpc, mid) >= ts:
            hi = mid
        else:
            lo = mid + 1
    return lo


def block_at_or_before_ts(rpc, ts):
    """Highest block with timestamp <= ts, within the finalized head. If ts is at/after the finalized tip, the
    tip is the answer (the other chain can trail by seconds at the B boundary)."""
    tip = finalized_number(rpc)
    if ts >= block_ts(rpc, tip):
        return tip
    lo, hi = 0, tip
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if block_ts(rpc, mid) <= ts:
            lo = mid
        else:
            hi = mid - 1
    return lo


def resolve_anchors(base, eth, t_b, genesis_block=None):
    """Anchors from T_B. In genesis mode (B = the token's deployment block, not chosen by anyone),
    T_B := timestamp(genesis block); B must resolve to that very block — asserted, since Base
    timestamps are strictly increasing so first-block-with-ts>=T_B is the genesis block itself."""
    B = block_at_or_after_ts(base, t_b)
    if genesis_block is not None and B != genesis_block:
        raise RuntimeError(f"genesis block {genesis_block} does not resolve from its own timestamp (got {B})")
    tsB = block_ts(base, B)
    B2 = block_at_or_after_ts(base, t_b - TWO_WEEKS_S)
    L = block_at_or_before_ts(eth, tsB)
    L2 = block_at_or_before_ts(eth, tsB - TWO_WEEKS_S)
    B_age = block_at_or_before_ts(base, tsB - MIN_AGE_S)   # §3.2 age cutoff, Base side
    L_age = block_at_or_before_ts(eth, tsB - MIN_AGE_S)    # §3.2 age cutoff, Ethereum side
    return {
        "T_B": t_b, "B": B, "B2": B2, "L": L, "L2": L2, "B_age": B_age, "L_age": L_age,
        "ts_B": tsB, "ts_B2": block_ts(base, B2), "ts_L": block_ts(eth, L), "ts_L2": block_ts(eth, L2),
        "ts_Bage": block_ts(base, B_age), "ts_Lage": block_ts(eth, L_age),
    }


# ------------------------------------------------------------------ candidate enumeration (§2)
WORKERS = int(os.environ.get("SNAPSHOT_WORKERS", "8"))  # concurrent HTTP batches; pure reads → order-free


def enumerate_senders(rpc, from_blk, to_blk):
    """Union of tx senders in (from_blk, to_blk]. Concurrency note: a set union is order-independent,
    so worker completion order cannot change the result (determinism preserved)."""
    senders = set()
    lock = threading.Lock()
    nums = list(range(from_blk + 1, to_blk + 1))
    done = [0]

    def scan(start):
        chunk = nums[start:start + rpc.batch]
        blocks = rpc.batch_call([("eth_getBlockByNumber", [hexblk(n), True]) for n in chunk])
        local = set()
        for blk in blocks:
            for tx in blk.get("transactions", []):
                f = tx.get("from")
                if f:
                    local.add(f.lower())
        with lock:
            senders.update(local)
            done[0] += len(chunk)
            if done[0] % 20_000 < rpc.batch:
                print(f"  ... scanned {done[0]}/{len(nums)} blocks, {len(senders)} senders", file=sys.stderr)

    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        list(ex.map(scan, range(0, len(nums), rpc.batch)))
    return senders


# ------------------------------------------------------------------ pre-scan DB (builder acceleration)
# The genesis snapshot's enumeration window ends at B = the deploy block, which doesn't exist until the
# deploy lands. A pre-scan walks the chain AHEAD of time into a resumable sqlite DB (addr -> highest tx
# block seen); once B is known, build only tail-scans the few missing blocks and trims the DB to the
# window. Equivalence to enumerate_senders() over (X-W, X]:
#   last_block in (X-W, X]  ->  sender in window (their latest tx is in it)
#   last_block <= X-W       ->  every tx is at or before X-W -> not in window
#   last_block >  X         ->  undecidable from the max alone -> resolved EXACTLY by the nonce-diff
#                               fallback nonce(a, X) > nonce(a, X-W) (2 consensus reads; §2 of the spec)
def open_scan_db(path):
    db = sqlite3.connect(path)
    db.execute("CREATE TABLE IF NOT EXISTS senders(addr TEXT PRIMARY KEY, last_block INTEGER, last_nonce INTEGER)")
    db.execute("CREATE TABLE IF NOT EXISTS progress(k TEXT PRIMARY KEY, v INTEGER)")
    return db


def scan_to_db(rpc, db, from_blk, to_blk):
    """Scan [from_blk, to_blk] recording each sender's highest tx block (+ that tx's nonce). Resumable:
    restarts continue at the checkpoint; the max-merge upsert is idempotent and order-independent."""
    row = db.execute("SELECT v FROM progress WHERE k='next'").fetchone()
    if row is None:
        db.execute("INSERT INTO progress VALUES('start',?)", (from_blk,))
        nxt = from_blk
    else:
        nxt = max(from_blk, row[0])
    wave = rpc.batch * WORKERS
    while nxt <= to_blk:
        nums = list(range(nxt, min(nxt + wave - 1, to_blk) + 1))

        def fetch(start):
            chunk = nums[start:start + rpc.batch]
            return rpc.batch_call([("eth_getBlockByNumber", [hexblk(n), True]) for n in chunk])

        with ThreadPoolExecutor(max_workers=WORKERS) as ex:
            waves = list(ex.map(fetch, range(0, len(nums), rpc.batch)))
        rows = {}
        for blocks in waves:
            for blk in blocks:
                bn = to_int(blk["number"])
                for tx in blk.get("transactions", []):
                    f = tx.get("from")
                    if f:
                        f = f.lower()
                        cur = rows.get(f)
                        if cur is None or bn > cur[0]:
                            # last_nonce is informational only (NEVER used in the predicate or the candidate
                            # trim); some gateways omit "nonce" on OP-stack deposit txs — store -1 then.
                            n = tx.get("nonce")
                            rows[f] = (bn, to_int(n) if n is not None else -1)
        db.executemany(
            "INSERT INTO senders VALUES(?,?,?) ON CONFLICT(addr) DO UPDATE SET "
            "last_block=excluded.last_block, last_nonce=excluded.last_nonce "
            "WHERE excluded.last_block>senders.last_block",
            [(a, b, n) for a, (b, n) in rows.items()])
        nxt = nums[-1] + 1
        db.execute("INSERT INTO progress VALUES('next',?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", (nxt,))
        db.commit()
        if (nxt // wave) % 10 == 0 or nxt > to_blk:
            total = db.execute("SELECT COUNT(*) FROM senders").fetchone()[0]
            print(f"  ... scan at {nxt - 1}/{to_blk} ({to_blk - nxt + 1} blocks left), {total} senders",
                  file=sys.stderr)


def senders_from_db(rpc, db, X, W):
    """Candidate set over window (X-W, X] from a pre-scan DB — provably identical to enumerate_senders."""
    start_row = db.execute("SELECT v FROM progress WHERE k='start'").fetchone()
    next_row = db.execute("SELECT v FROM progress WHERE k='next'").fetchone()
    if not start_row or start_row[0] > X - W + 1:
        raise RuntimeError(f"scan DB starts at {start_row and start_row[0]} > window start {X - W + 1}")
    if not next_row or next_row[0] - 1 < X:
        missing_from = next_row[0] if next_row else X - W + 1
        print(f"  tail-scanning ({missing_from - 1}, {X}] to complete the window", file=sys.stderr)
        scan_to_db(rpc, db, missing_from, X)
    in_win = {r[0] for r in db.execute(
        "SELECT addr FROM senders WHERE last_block > ? AND last_block <= ?", (X - W, X))}
    over = [r[0] for r in db.execute("SELECT addr FROM senders WHERE last_block > ?", (X,))]
    if over:  # deploy landed while the scan ran past it: settle those few by nonce-diff (exact)
        print(f"  nonce-diff recheck for {len(over)} senders past block {X}", file=sys.stderr)
        n_hi = rpc.batch_call([("eth_getTransactionCount", [a, hexblk(X)]) for a in over])
        n_lo = rpc.batch_call([("eth_getTransactionCount", [a, hexblk(X - W)]) for a in over])
        in_win |= {a for a, h, l in zip(over, n_hi, n_lo) if to_int(h) > to_int(l)}
    return in_win


# ------------------------------------------------------------------ per-candidate predicate (§3)
def eligible(reads):
    bal_now = reads["balBase_B"] + reads["balL1_L"]
    bal_2wk = reads["balBase_B2"] + reads["balL1_L2"]
    if not (FLOOR_WEI <= bal_now < CAP_WEI and FLOOR_WEI <= bal_2wk < CAP_WEI):
        return False
    txs = reads["nonceBase_B"] + reads["nonceL1_L"]
    if not (MIN_TXS <= txs <= MAX_TXS):
        return False
    # §3.2 age: had sent a tx by the 12-months-before cutoff on either chain (nonce >= 1 at the cutoff block)
    if not (reads["nonceBase_Bage"] >= 1 or reads["nonceL1_Lage"] >= 1):
        return False
    c = reads["code_B"].lower()
    is_eoa = c == "0x"
    is_7702 = c.startswith(EIP7702_PREFIX) and len(c) == 2 + 46  # "0x" + 23 bytes
    return is_eoa or is_7702


CHUNK = 1000  # candidates per cross-candidate batch pass (bounds memory; each pass = ~5k Base + 4k L1 reads)


def evaluate(base, eth, cand_sorted, anchors, exclusions):
    """Cross-candidate batched: for each chunk of candidates, issue ALL of that chunk's Base reads (5/candidate)
    and ALL its L1 reads (4/candidate) as batches, then apply the predicate. Result-identical to per-candidate;
    ~one HTTP round-trip per 100 reads instead of per candidate — the difference between hours and minutes at
    genesis scale. (batch_call still aborts loudly on any errored/missing read → no silent corruption.)"""
    B, B2, L, L2 = anchors["B"], anchors["B2"], anchors["L"], anchors["L2"]
    Bage, Lage = anchors["B_age"], anchors["L_age"]
    excl = set(a.lower() for a in exclusions)
    cand = [a for a in cand_sorted if a not in excl]
    lock = threading.Lock()
    reads_used = [0]   # cost accounting
    done = [0]

    def eval_chunk(start):
        cs = cand[start:start + CHUNK]
        # PASS 1 — cheap balance-at-B pre-filter (2 reads/candidate). balance-at-B in [floor,cap) is a NECESSARY
        # condition, so anything failing it is ineligible regardless of the other reads — result-identical.
        p1b = base.batch_call([("eth_getBalance", [a, hexblk(B)]) for a in cs])
        p1e = eth.batch_call([("eth_getBalance", [a, hexblk(L)]) for a in cs])
        survivors = []
        for j, a in enumerate(cs):
            bb0, le0 = to_int(p1b[j]), to_int(p1e[j])
            if FLOOR_WEI <= bb0 + le0 < CAP_WEI:
                survivors.append((a, bb0, le0))
        chunk_out = []
        # PASS 2 — full eval only on survivors (7 more reads each)
        if survivors:
            addrs = [s[0] for s in survivors]
            b2 = base.batch_call([c for a in addrs for c in (
                ("eth_getBalance", [a, hexblk(B2)]), ("eth_getTransactionCount", [a, hexblk(B)]),
                ("eth_getCode", [a, hexblk(B)]), ("eth_getTransactionCount", [a, hexblk(Bage)]))])
            e2 = eth.batch_call([c for a in addrs for c in (
                ("eth_getBalance", [a, hexblk(L2)]), ("eth_getTransactionCount", [a, hexblk(L)]),
                ("eth_getTransactionCount", [a, hexblk(Lage)]))])
            for k, (a, balB, balL) in enumerate(survivors):
                bb, le = b2[4 * k:4 * k + 4], e2[3 * k:3 * k + 3]
                reads = {
                    "balBase_B": balB, "balBase_B2": to_int(bb[0]), "nonceBase_B": to_int(bb[1]),
                    "code_B": bb[2], "nonceBase_Bage": to_int(bb[3]),
                    "balL1_L": balL, "balL1_L2": to_int(le[0]), "nonceL1_L": to_int(le[1]),
                    "nonceL1_Lage": to_int(le[2]),
                }
                if eligible(reads):
                    chunk_out.append(a)
        with lock:
            reads_used[0] += 2 * len(cs) + 7 * len(survivors)
            done[0] += len(cs)
            print(f"  ... {done[0]}/{len(cand)} evaluated (+{len(chunk_out)} eligible in chunk), "
                  f"{reads_used[0]} reads used", file=sys.stderr)
        return chunk_out

    # Concurrent chunks, merged IN CHUNK ORDER — the output list is identical to the sequential run
    # (candidates are pre-sorted; per-chunk evaluation is pure reads), so determinism is preserved.
    starts = list(range(0, len(cand), CHUNK))
    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        per_chunk = list(ex.map(eval_chunk, starts))
    return [a for chunk in per_chunk for a in chunk]


# ------------------------------------------------------------------ header (§7)
def header_hash(hdr):
    h = {k: v for k, v in hdr.items() if k != "header_keccak"}
    return "0x" + keccak256(json.dumps(h, sort_keys=True, separators=(",", ":")).encode()).hex()


def build_header(anchors, w_base, w_l1, exclusions, candidates_sorted, set_root, n):
    hdr = {
        "rule": RULE_ID,
        "T_B": anchors["T_B"], "B": anchors["B"], "B2": anchors["B2"], "L": anchors["L"], "L2": anchors["L2"],
        "B_age": anchors["B_age"], "L_age": anchors["L_age"],
        "ts_B": anchors["ts_B"], "ts_B2": anchors["ts_B2"], "ts_L": anchors["ts_L"], "ts_L2": anchors["ts_L2"],
        "ts_Bage": anchors["ts_Bage"], "ts_Lage": anchors["ts_Lage"],
        "W_base": w_base, "W_l1": w_l1,
        "floor_wei": FLOOR_WEI, "cap_wei": CAP_WEI,
        "min_age_s": MIN_AGE_S, "min_txs": MIN_TXS, "max_txs": MAX_TXS,
        "exclusions": sorted(a.lower() for a in exclusions),
        "candidates_keccak": "0x" + keccak256("\n".join(candidates_sorted).encode()).hex(),
        "setRoot": set_root, "N": n,
    }
    hdr["header_keccak"] = header_hash(hdr)
    return hdr


def validate_addrs(addrs, what):
    for a in addrs:
        if not ADDR_RE.match(a):
            sys.exit(f"{what}: not a lowercase 0x-address: {a!r}")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--t-b", type=int, help="snapshot timestamp (first Base block with ts >= T_B becomes B)")
    b.add_argument("--genesis-block", type=int,
                   help="genesis mode: B = this Base block (the token's deployment block); T_B := its timestamp")
    b.add_argument("--w-base", type=int, default=630_000)
    b.add_argument("--w-l1", type=int, default=100_800)
    b.add_argument("--exclude", default="")
    b.add_argument("--out", required=True)
    b.add_argument("--scan-db-base", help="pre-scan sqlite for Base (else direct block enumeration)")
    b.add_argument("--scan-db-eth", help="pre-scan sqlite for Ethereum L1")
    s = sub.add_parser("scan", help="resumable pre-scan of tx senders into a sqlite DB (before B exists)")
    s.add_argument("--chain", choices=["base", "eth"], required=True)
    s.add_argument("--db", required=True)
    s.add_argument("--lookback", type=int, required=True, help="blocks back from the target tip")
    s.add_argument("--to-block", type=int, help="scan up to this block (default: finalized tip now)")
    v = sub.add_parser("verify")
    v.add_argument("--header", required=True)
    v.add_argument("--candidates", required=True)
    v.add_argument("--expect-root", required=True)
    v.add_argument("--expect-n", type=int, required=True)
    a = ap.parse_args()

    base = make_rpc("BASE_RPC_URL", "BASE_RPC_URLS")   # BASE_RPC_URLS=url1,url2,... → MultiRPC rotation
    eth = make_rpc("ETH_RPC_URL", "ETH_RPC_URLS")

    if a.cmd == "build":
        if (a.t_b is None) == (a.genesis_block is None):
            sys.exit("build: pass exactly one of --t-b or --genesis-block")
        excl = [x.strip().lower() for x in a.exclude.split(",") if x.strip()]
        validate_addrs(excl, "--exclude")
        t_b = a.t_b if a.t_b is not None else block_ts(base, a.genesis_block)
        anchors = resolve_anchors(base, eth, t_b, genesis_block=a.genesis_block)
        print(f"B={anchors['B']} B2={anchors['B2']} L={anchors['L']} L2={anchors['L2']}", file=sys.stderr)
        base_set = (senders_from_db(base, open_scan_db(a.scan_db_base), anchors["B"], a.w_base)
                    if a.scan_db_base else enumerate_senders(base, anchors["B"] - a.w_base, anchors["B"]))
        eth_set = (senders_from_db(eth, open_scan_db(a.scan_db_eth), anchors["L"], a.w_l1)
                   if a.scan_db_eth else enumerate_senders(eth, anchors["L"] - a.w_l1, anchors["L"]))
        cand = sorted(base_set | eth_set)
        print(f"candidates: {len(cand)}", file=sys.stderr)
        eligible_list = evaluate(base, eth, cand, anchors, excl)
        set_root = "0x" + MerkleTree([leaf_v2(x) for x in eligible_list]).root.hex() if eligible_list else None
        hdr = build_header(anchors, a.w_base, a.w_l1, excl, cand, set_root, len(eligible_list))
        os.makedirs(a.out, exist_ok=True)
        open(os.path.join(a.out, "candidates.txt"), "w").write("\n".join(cand))
        open(os.path.join(a.out, "eligible.txt"), "w").write("\n".join(eligible_list))
        json.dump(hdr, open(os.path.join(a.out, "header.json"), "w"), indent=1)
        print(f"eligible: {len(eligible_list)}  setRoot: {set_root}  header_keccak: {hdr['header_keccak']}")
        print(f"next: python3 build_v2_proofs.py --addresses {a.out}/eligible.txt --out ../site/data")
        print(f"      then commitSet(setRoot={set_root}, N={len(eligible_list)}, sealTimestamp)")

    elif a.cmd == "scan":
        rpc = base if a.chain == "base" else eth
        to_blk = a.to_block if a.to_block is not None else finalized_number(rpc)
        print(f"scan {a.chain}: [{to_blk - a.lookback}, {to_blk}] -> {a.db}", file=sys.stderr)
        scan_to_db(rpc, open_scan_db(a.db), to_blk - a.lookback, to_blk)
        print("scan done", file=sys.stderr)

    elif a.cmd == "verify":
        hdr = json.load(open(a.header))
        if header_hash(hdr) != hdr.get("header_keccak"):
            sys.exit("FAIL: header_keccak does not match the header contents")
        cand = sorted(set(x.strip().lower() for x in open(a.candidates) if x.strip()))
        validate_addrs(cand, "candidates")
        if "0x" + keccak256("\n".join(cand).encode()).hex() != hdr["candidates_keccak"]:
            sys.exit("FAIL: candidate dump hash != header candidates_keccak")
        # re-derive the anchors from T_B and assert the header did not doctor them
        red = resolve_anchors(base, eth, hdr["T_B"])
        for k in ("B", "B2", "L", "L2", "B_age", "L_age", "ts_B", "ts_B2", "ts_L", "ts_L2", "ts_Bage", "ts_Lage"):
            if red[k] != hdr[k]:
                sys.exit(f"FAIL: header {k}={hdr[k]} but re-derived {red[k]}")
        eligible_list = evaluate(base, eth, cand, red, hdr["exclusions"])
        root = "0x" + MerkleTree([leaf_v2(x) for x in eligible_list]).root.hex() if eligible_list else None
        ok_n = len(eligible_list) == a.expect_n
        ok_r = root == a.expect_root.lower()
        print(f"reproduced N={len(eligible_list)} (expect {a.expect_n}) {'OK' if ok_n else 'MISMATCH'}")
        print(f"reproduced setRoot={root} (expect {a.expect_root}) {'OK' if ok_r else 'MISMATCH'}")
        sys.exit(0 if (ok_n and ok_r) else 1)


if __name__ == "__main__":
    main()
