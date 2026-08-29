"""Tiny JSON-RPC helper (stdlib only) with batching + thread pool."""
import json
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor


class Rpc:
    def __init__(self, url: str, workers: int = 8, retries: int = 5):
        self.url, self.workers, self.retries = url, workers, retries

    def _post(self, payload):
        data = json.dumps(payload).encode()
        for attempt in range(self.retries):
            try:
                req = urllib.request.Request(self.url, data=data, headers={"content-type": "application/json", "user-agent": "2btc-lottery/1.0"})
                with urllib.request.urlopen(req, timeout=120) as r:
                    return json.load(r)
            except Exception as e:  # noqa: BLE001
                if attempt == self.retries - 1:
                    raise
                time.sleep(1.5 * (attempt + 1))

    @staticmethod
    def _is_rate_limit(err) -> bool:
        msg = json.dumps(err).lower()
        return any(k in msg for k in ("rate limit", "too many", "429", "-32016", "-32005", "capacity", "exceeded"))

    def call(self, method, params):
        for attempt in range(self.retries + 3):
            res = self._post({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
            if "error" in res:
                if self._is_rate_limit(res["error"]):
                    time.sleep(2.0 * (attempt + 1))
                    continue
                raise RuntimeError(f"{method}: {res['error']}")
            return res["result"]
        raise RuntimeError(f"{method}: rate limited repeatedly")

    def batch(self, calls):
        """calls: list of (method, params) → list of results (same order). Retries on rate limits."""
        payload = [{"jsonrpc": "2.0", "id": i, "method": m, "params": p} for i, (m, p) in enumerate(calls)]
        for attempt in range(self.retries + 3):
            res = self._post(payload)
            if isinstance(res, dict) and "error" in res:
                if self._is_rate_limit(res["error"]):
                    time.sleep(2.0 * (attempt + 1))
                    continue
                raise RuntimeError(res["error"])
            out = [None] * len(calls)
            limited = False
            for r in res:
                if "error" in r:
                    if self._is_rate_limit(r["error"]):
                        limited = True
                        break
                    raise RuntimeError(f"{calls[r['id']][0]}: {r['error']}")
                out[r["id"]] = r["result"]
            if limited:
                time.sleep(2.0 * (attempt + 1))
                continue
            return out
        raise RuntimeError("batch: rate limited repeatedly")

    def map(self, fn, items):
        with ThreadPoolExecutor(max_workers=self.workers) as ex:
            return list(ex.map(fn, items))
