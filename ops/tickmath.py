"""Exact port of Uniswap v3 TickMath.getSqrtRatioAtTick / getTickAtSqrtRatio (integer math, no floats)."""

MIN_TICK = -887272
MAX_TICK = 887272
MIN_SQRT_RATIO = 4295128739
MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342
U256 = (1 << 256) - 1

_STEPS = [
    (0x2, 0xfff97272373d413259a46990580e213a), (0x4, 0xfff2e50f5f656932ef12357cf3c7fdcc),
    (0x8, 0xffe5caca7e10e4e61c3624eaa0941cd0), (0x10, 0xffcb9843d60f6159c9db58835c926644),
    (0x20, 0xff973b41fa98c081472e6896dfb254c0), (0x40, 0xff2ea16466c96a3843ec78b326b52861),
    (0x80, 0xfe5dee046a99a2a811c461f1969c3053), (0x100, 0xfcbe86c7900a88aedcffc83b479aa3a4),
    (0x200, 0xf987a7253ac413176f2b074cf7815e54), (0x400, 0xf3392b0822b70005940c7a398e4b70f3),
    (0x800, 0xe7159475a2c29b7443b29c7fa6e889d9), (0x1000, 0xd097f3bdfd2022b8845ad8f792aa5825),
    (0x2000, 0xa9f746462d870fdf8a65dc1f90e061e5), (0x4000, 0x70d869a156d2a1b890bb3df62baf32f7),
    (0x8000, 0x31be135f97d08fd981231505542fcfa6), (0x10000, 0x9aa508b5b7a84e1c677de54f3e99bc9),
    (0x20000, 0x5d6af8dedb81196699c329225ee604), (0x40000, 0x2216e584f5fa1ea926041bedfe98),
    (0x80000, 0x48a170391f7dc42444e8fa2),
]


def get_sqrt_ratio_at_tick(tick: int) -> int:
    assert MIN_TICK <= tick <= MAX_TICK, "tick out of range"
    abs_tick = -tick if tick < 0 else tick
    ratio = 0xfffcb933bd6fad37aa2d162d1a594001 if abs_tick & 1 else 0x100000000000000000000000000000000
    for bit, c in _STEPS:
        if abs_tick & bit:
            ratio = (ratio * c) >> 128
    if tick > 0:
        ratio = U256 // ratio
    return (ratio >> 32) + (0 if ratio % (1 << 32) == 0 else 1)


def get_tick_at_sqrt_ratio(sqrt_price_x96: int) -> int:
    """Largest tick t such that get_sqrt_ratio_at_tick(t) <= sqrt_price_x96 (binary search, exact)."""
    assert MIN_SQRT_RATIO <= sqrt_price_x96 < MAX_SQRT_RATIO
    lo, hi = MIN_TICK, MAX_TICK
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if get_sqrt_ratio_at_tick(mid) <= sqrt_price_x96:
            lo = mid
        else:
            hi = mid - 1
    return lo


if __name__ == "__main__":
    assert get_sqrt_ratio_at_tick(0) == 1 << 96
    assert get_sqrt_ratio_at_tick(MIN_TICK) == MIN_SQRT_RATIO, get_sqrt_ratio_at_tick(MIN_TICK)
    assert get_sqrt_ratio_at_tick(MAX_TICK) == MAX_SQRT_RATIO, get_sqrt_ratio_at_tick(MAX_TICK)
    for t in (-887200, -200, 0, 200, 12345, 887200):
        assert get_tick_at_sqrt_ratio(get_sqrt_ratio_at_tick(t)) == t
    print("tickmath self-test OK")
