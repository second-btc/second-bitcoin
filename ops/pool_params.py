#!/usr/bin/env python3
"""Compute seedPool() parameters for a single-sided Uniswap v3 position (zero ETH).

  usage: pool_params.py --token 0x... [--weth 0x4200...0006] [--fee 10000] (--p0-eth X | --fdv-usd F --eth-usd E)

Prints sqrtPriceX96 / tickLower / tickUpper. The pool is initialised exactly on a tick boundary so the
position [tick, MAX] (2BTC = token0) or [MIN, tick] (2BTC = token1) holds only 2BTC at genesis.
"""
import argparse
import json
import math
import os
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tickmath import MAX_TICK, MIN_TICK, get_sqrt_ratio_at_tick  # noqa: E402

WETH = "0x4200000000000000000000000000000000000006"
TOKEN_DECIMALS = 8
WETH_DECIMALS = 18
SPACING = {500: 10, 3000: 60, 10000: 200}


def eth_usd() -> float:
    with urllib.request.urlopen("https://api.coinbase.com/v2/prices/ETH-USD/spot", timeout=15) as r:
        return float(json.load(r)["data"]["amount"])


def params(token: str, weth: str, fee: int, p0_eth: float, existing_tick=None):
    """If the pair already exists (someone created it first), pass its slot0 tick as existing_tick: the
    position is then placed strictly on the 2BTC side of the current price (sqrtPriceX96 is ignored by
    createAndInitializePoolIfNecessary in that case)."""
    spacing = SPACING[fee]
    we_are_token0 = int(token, 16) < int(weth, 16)
    # v3 price = token1_raw / token0_raw
    if we_are_token0:
        price = p0_eth * 10 ** (WETH_DECIMALS - TOKEN_DECIMALS)
    else:
        price = 1.0 / (p0_eth * 10 ** (WETH_DECIMALS - TOKEN_DECIMALS))
    raw_tick = math.log(price) / math.log(1.0001)
    tick = int(round(raw_tick / spacing)) * spacing
    tick = max(MIN_TICK + (-MIN_TICK % spacing), min(MAX_TICK - (MAX_TICK % spacing), tick))
    if existing_tick is not None:
        # 2BTC = token0 → range must start above the current tick; 2BTC = token1 → range must end at/below it
        if we_are_token0:
            tick = (existing_tick // spacing + 1) * spacing
        else:
            tick = (existing_tick // spacing) * spacing
            if tick >= existing_tick:
                tick -= spacing
    sqrt_price_x96 = get_sqrt_ratio_at_tick(tick)
    if we_are_token0:
        lower, upper = tick, MAX_TICK - (MAX_TICK % spacing)
    else:
        lower, upper = MIN_TICK + (-MIN_TICK % spacing), tick
    # effective P0 after rounding to the tick grid
    eff_price = 1.0001 ** tick
    eff_p0 = eff_price / 10 ** (WETH_DECIMALS - TOKEN_DECIMALS) if we_are_token0 else 1.0 / (eff_price * 10 ** (WETH_DECIMALS - TOKEN_DECIMALS))
    return {
        "token": token, "weth": weth, "fee": fee, "weAreToken0": we_are_token0,
        "tick": tick, "sqrtPriceX96": sqrt_price_x96, "tickLower": lower, "tickUpper": upper,
        "p0_eth_requested": p0_eth, "p0_eth_effective": eff_p0,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--token", help="token address (ordering known) — or use --both before deployment")
    ap.add_argument("--both", action="store_true", help="emit parameters for both orderings (2BTC as token0 / token1); used by the Launcher")
    ap.add_argument("--weth", default=WETH)
    ap.add_argument("--fee", type=int, default=10000)
    ap.add_argument("--p0-eth", type=float, help="starting price, ETH per coin")
    ap.add_argument("--fdv-usd", type=float, help="alternative: starting fully-diluted valuation in USD")
    ap.add_argument("--eth-usd", type=float, help="ETH/USD (fetched from Coinbase if omitted)")
    ap.add_argument("--supply", type=float, default=210_000)
    ap.add_argument("--existing-tick", type=int, default=None, help="slot0 tick of an already-created pair (cast call <pool> 'slot0()')")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    if a.p0_eth is None:
        assert a.fdv_usd, "give --p0-eth or --fdv-usd"
        e = a.eth_usd or eth_usd()
        a.p0_eth = a.fdv_usd / a.supply / e
        a.eth_usd = e
    if a.both:
        # a fake low address (token0 case) and a fake high address (token1 case) — only the ordering matters
        r0 = params("0x0000000000000000000000000000000000000001", a.weth, a.fee, a.p0_eth, a.existing_tick)
        r1 = params("0xffffffffffffffffffffffffffffffffffffffff", a.weth, a.fee, a.p0_eth, a.existing_tick)
        r = {"p0_eth_requested": a.p0_eth, "p0_eth_effective_token0": r0["p0_eth_effective"], "p0_eth_effective_token1": r1["p0_eth_effective"],
             "SQRT0": r0["sqrtPriceX96"], "TL0": r0["tickLower"], "TU0": r0["tickUpper"],
             "SQRT1": r1["sqrtPriceX96"], "TL1": r1["tickLower"], "TU1": r1["tickUpper"]}
        if a.eth_usd:
            r["eth_usd"] = a.eth_usd
        if a.json:
            print(json.dumps(r, indent=1))
        else:
            print(" ".join(f"{k}={v}" for k, v in r.items() if k in ("SQRT0", "TL0", "TU0", "SQRT1", "TL1", "TU1")))
        return
    assert a.token, "give --token or --both"
    r = params(a.token, a.weth, a.fee, a.p0_eth, a.existing_tick)
    if a.eth_usd:
        r["eth_usd"] = a.eth_usd
        r["fdv_usd_effective"] = r["p0_eth_effective"] * a.supply * a.eth_usd
    if a.json:
        print(json.dumps(r, indent=1))
    else:
        for k, v in r.items():
            print(f"{k:>20}: {v}")


if __name__ == "__main__":
    main()
