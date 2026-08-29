"""The Second Bitcoin halving draw — deterministic, dependency-free, reproducible.

    seed(k)   = sha256( "2BTC" || uint256(k) || btc_block_hash(H_k),  H_k = H0 + 2100·k(k+1)/2 )
    stream    = sha256(seed || uint64(i)) for i = 0,1,2,...   consumed as big-endian uint64 words
    rand(n)   = rejection sampling on uint64 → uniform in [0, n)
    draw t    : piece  = 5 + rand(46)                      (whole coins; 1 coin = 1e8 units)
                recipient = partial Fisher–Yates pick over the sorted snapshot (without replacement)
                if remaining < piece: piece = remaining (the last, possibly < 5 coin, draw)
    stop      : remaining == 0  (or snapshot exhausted)

Nobody — the operator included — can choose recipients unnoticed: the snapshot is committed on-chain before the
Bitcoin block that seeds it exists, and this file turns (snapshot, block hash, cap) into one unique list.
"""
import hashlib
import json


class Prng:
    """SHA-256 counter-mode stream of uint64 words."""

    def __init__(self, seed: bytes):
        self.seed = seed
        self.counter = 0
        self.buf = b""

    def _refill(self):
        self.buf += hashlib.sha256(self.seed + self.counter.to_bytes(8, "big")).digest()
        self.counter += 1

    def u64(self) -> int:
        if len(self.buf) < 8:
            self._refill()
        w, self.buf = int.from_bytes(self.buf[:8], "big"), self.buf[8:]
        return w

    def below(self, n: int) -> int:
        assert n > 0
        limit = (1 << 64) - ((1 << 64) % n)  # largest multiple of n ≤ 2^64
        while True:
            u = self.u64()
            if u < limit:
                return u % n


def seed_for(domain: str, k: int, btc_hash_hex: str) -> bytes:
    h = bytes.fromhex(btc_hash_hex.lower().replace("0x", ""))
    assert len(h) == 32, "btc block hash must be 32 bytes"
    return hashlib.sha256(domain.encode() + k.to_bytes(32, "big") + h).digest()


def draw(snapshot: list, k: int, btc_hash_hex: str, cap_units: int, cfg: dict):
    """Return list of (address, amount_units) in draw order."""
    unit = 10 ** cfg["token"]["decimals"]
    pmin, pmax = cfg["piece"]["min_coins"], cfg["piece"]["max_coins"]
    span = pmax - pmin + 1
    prng = Prng(seed_for(cfg["token"]["domain"], k, btc_hash_hex))
    pool = list(snapshot)  # sorted ascending by caller
    n = len(pool)
    out = []
    remaining = cap_units
    i = 0
    while remaining > 0 and i < n:
        piece = (pmin + prng.below(span)) * unit
        if piece > remaining:
            piece = remaining
        j = i + prng.below(n - i)
        pool[i], pool[j] = pool[j], pool[i]
        out.append((pool[i], piece))
        remaining -= piece
        i += 1
    return out


def load_snapshot(path: str):
    """Returns (sorted address list, sha256 of the file bytes, header dict)."""
    raw = open(path, "rb").read()
    digest = hashlib.sha256(raw).hexdigest()
    lines = raw.decode().split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    header = {}
    if lines and lines[0].startswith("#"):
        for kv in lines.pop(0).lstrip("# ").split():
            if "=" in kv:
                k, v = kv.split("=", 1)
                header[k] = v
    addrs = lines
    assert all(a == a.lower() and a.startswith("0x") and len(a) == 42 for a in addrs), "bad address format"
    assert addrs == sorted(addrs), "snapshot must be sorted ascending"
    assert len(set(addrs)) == len(addrs), "duplicate addresses"
    return addrs, digest, header


def load_config(path="config.json"):
    return json.load(open(path))
