#!/usr/bin/env python3
"""Generate glecimal's test vectors from Python's decimal module.

The oracle is independent of glecimal: exact operations run at a precision far
beyond the bounds with Inexact trapped, quotients are computed with ROUND_05UP
(safe against double rounding) and then quantized with the requested mode,
and allocation is computed with exact fractions. Only the bounds come from
glecimal's contract.

    scripts/vectors.py           write test/vectors/glecimal.json
    scripts/vectors.py --check   fail if the committed file differs
"""

import json
import random
import sys
from decimal import (
    ROUND_05UP,
    ROUND_CEILING,
    ROUND_DOWN,
    ROUND_FLOOR,
    ROUND_HALF_DOWN,
    ROUND_HALF_EVEN,
    ROUND_HALF_UP,
    ROUND_UP,
    Context,
    Decimal,
    Inexact,
    localcontext,
)
from fractions import Fraction
from pathlib import Path

OUTPUT = Path(__file__).resolve().parent.parent / "test" / "vectors" / "glecimal.json"

MAX_DIGITS = 128
MAX_SCALE = 64
MAX_TEXT_BYTES = 1 + MAX_DIGITS + 1
MAX_POWER_DIGITS = 10_000

ROUNDINGS = {
    "half_even": ROUND_HALF_EVEN,
    "half_away_from_zero": ROUND_HALF_UP,
    "half_toward_zero": ROUND_HALF_DOWN,
    "toward_zero": ROUND_DOWN,
    "away_from_zero": ROUND_UP,
    "floor": ROUND_FLOOR,
    "ceiling": ROUND_CEILING,
}

EXACT = Context(prec=100_000, traps=[Inexact])


def text(value: Decimal) -> str:
    """The canonical form: plain digits at the value's scale, no negative zero."""
    if value.is_zero():
        value = abs(value)
    return format(value, "f")


def scale_of(value: Decimal) -> int:
    return max(0, -value.as_tuple().exponent)


def digit_count(value: Decimal) -> int:
    """Significant digits of the unscaled value; every value here has an
    exponent of at most 0."""
    digits = value.as_tuple().digits
    return len("".join(map(str, digits)).lstrip("0"))


def bounded(value: Decimal) -> dict:
    if scale_of(value) > MAX_SCALE or digit_count(value) > MAX_DIGITS:
        return {"error": "overflow"}
    return {"ok": text(value)}


def quantized(value, scale: int, rounding: str) -> dict:
    """Rounds an exact Decimal or Fraction to `scale` with `rounding`."""
    if isinstance(value, Fraction):
        with localcontext(Context(prec=1_000, rounding=ROUND_05UP)):
            value = Decimal(value.numerator) / Decimal(value.denominator)
    target = Decimal(1).scaleb(-scale)
    with localcontext(Context(prec=100_000)):
        return bounded(value.quantize(target, rounding=ROUNDINGS[rounding]))


def parse(raw: str) -> dict:
    if len(raw.encode()) > MAX_TEXT_BYTES:
        return {"error": "too_long"}
    body = raw[1:] if raw.startswith("-") else raw
    whole, point, fraction = body.partition(".")
    ascii_digits = lambda part: all("0" <= c <= "9" for c in part)
    if not whole or (point and not fraction) or not ascii_digits(whole) or not ascii_digits(fraction):
        return {"error": "syntax"}
    if len(fraction) > MAX_SCALE or len((whole + fraction).lstrip("0")) > MAX_DIGITS:
        return {"error": "too_long"}
    return {"ok": text(Decimal(raw))}


def arithmetic(op: str, a: Decimal, b: Decimal) -> dict:
    function = {"add": EXACT.add, "subtract": EXACT.subtract, "multiply": EXACT.multiply}[op]
    return bounded(function(a, b))


def multiply_rounded(a: Decimal, b: Decimal, scale: int, rounding: str) -> dict:
    if not 0 <= scale <= MAX_SCALE:
        return {"error": "scale"}
    return quantized(EXACT.multiply(a, b), scale, rounding)


def divide(a: Decimal, b: Decimal, scale: int, rounding: str) -> dict:
    if not 0 <= scale <= MAX_SCALE:
        return {"error": "scale"}
    if b.is_zero():
        return {"error": "division_by_zero"}
    return quantized(Fraction(a) / Fraction(b), scale, rounding)


def divide_with_remainder(a: Decimal, b: Decimal, scale: int) -> dict:
    """The quotient truncated toward zero at `scale`, and a − quotient × b
    exactly, at the larger of a's scale and scale + b's scale, or at most 64
    when its trailing digits are zeros."""
    if not 0 <= scale <= MAX_SCALE:
        return {"error": "scale"}
    if b.is_zero():
        return {"error": "division_by_zero"}
    units = int(Fraction(a) / Fraction(b) * 10**scale)  # int() truncates toward zero
    quotient = EXACT.scaleb(Decimal(units), -scale)
    if digit_count(quotient) > MAX_DIGITS:
        return {"error": "overflow"}
    remainder = Fraction(a) - Fraction(units, 10**scale) * Fraction(b)
    target = min(max(scale_of(a), scale + scale_of(b)), MAX_SCALE)
    remainder_units = remainder * 10**target
    if remainder_units.denominator != 1:
        return {"error": "overflow"}
    remainder = EXACT.scaleb(Decimal(int(remainder_units)), -target)
    if digit_count(remainder) > MAX_DIGITS:
        return {"error": "overflow"}
    return {"ok": [text(quotient), text(remainder)]}


def round_to(a: Decimal, scale: int, rounding: str) -> dict:
    if not 0 <= scale <= MAX_SCALE:
        return {"error": "scale"}
    return quantized(a, scale, rounding)


def rescale(a: Decimal, scale: int) -> dict:
    if not 0 <= scale <= MAX_SCALE:
        return {"error": "scale"}
    exact = Fraction(a) * 10**scale
    if exact.denominator != 1:
        return {"error": "would_round"}
    return quantized(a, scale, "half_even")


def power(a: Decimal, exponent: int, scale: int, rounding: str) -> dict:
    if not 0 <= scale <= MAX_SCALE:
        return {"error": "scale"}
    if abs(exponent) * (digit_count(a) + scale_of(a)) > MAX_POWER_DIGITS:
        return {"error": "power_too_large"}
    if a.is_zero() and exponent < 0:
        return {"error": "division_by_zero"}
    return quantized(Fraction(a) ** exponent, scale, rounding)


def allocate(amount: Decimal, weights: list) -> dict:
    if not weights:
        return {"error": "no_parts"}
    for index, weight in enumerate(weights):
        if weight < 0:
            return {"error": "negative_weight", "index": index}
    total = sum(Fraction(w) for w in weights)
    if total == 0:
        return {"error": "zero_total_weight"}
    scale = scale_of(amount)
    units = abs(Fraction(amount)) * 10**scale
    shares = [units * Fraction(w) / total for w in weights]
    floors = [share.numerator // share.denominator for share in shares]
    leftover = int(units) - sum(floors)
    ranked = sorted(range(len(shares)), key=lambda i: (-(shares[i] - floors[i]), i))
    for index in ranked[:leftover]:
        floors[index] += 1
    sign = -1 if amount < 0 else 1
    return {"ok": [text(EXACT.scaleb(Decimal(sign * f), -scale)) for f in floors]}


def compare(a: Decimal, b: Decimal) -> dict:
    return {"ok": (a > b) - (a < b)}


# ── Cases ────────────────────────────────────────────────────────────────────

PARSE_EDGES = [
    "0", "0.0", "0.00", "1", "-1", "1.50", "-1.50", "0.05", "-0.05", "0.000001",
    "123456789012345678901234567890",
    "-123456789012345678901234567890.123456789012345678901234567890",
    "10.0", "-0", "-0.00", "007", "-007.500", "000.1",
    "", "-", ".", "1.", ".5", "1e3", "1E3", "+1", "1,5", "1.000,5", " 1", "1 ",
    "--1", "-+1", "1.2.3", "1_000", "0x10", "NaN", "Infinity", "١", "１", "1́",
    "9" * 64 + "." + "9" * 32, "-" + "9" * 64 + "." + "9" * 32,
    "1" * 65, "-" + "1" * 65, "1." + "1" * 33, "1" * 10_000, "0" * 64 + ".5",
    "9" * 128, "-" + "9" * 128, "9" * 129, "9" * 64 + "." + "9" * 64,
    "-" + "9" * 64 + "." + "9" * 64, "0" + "9" * 64 + "." + "9" * 64,
    "00" + "9" * 64 + "." + "9" * 64, "9" * 65 + "." + "9" * 64,
    "0." + "0" * 63 + "1", "-0." + "0" * 63 + "1", "0." + "0" * 64 + "1",
    "0." + "1" * 64, "0." + "1" * 65, "0" * 120 + "1", "0" * 129 + "1",
]

ROUND_EDGES = [
    ("2.5", 0), ("-2.5", 0), ("3.5", 0), ("-3.5", 0), ("0.5", 0), ("-0.5", 0),
    ("0.125", 2), ("-0.125", 2), ("0.135", 2), ("2.4999", 0), ("-2.4999", 0),
    ("2.5001", 0), ("-2.5001", 0), ("2.5000000000000000000001", 0), ("0.001", 2),
    ("-0.001", 2), ("2.50", 1), ("-2.00", 0), ("0.00", 0), ("1.5", 3), ("-1.5", 3),
    ("7", 2), ("9.995", 2), ("-9.995", 2), ("1.5", -1), ("1.5", 65), ("1", 64),
    ("9" * 64, 64), ("9" * 64, 63), ("0." + "9" * 32, 0),
]

DIVIDE_EDGES = [
    ("1", "3", 6), ("-1", "3", 6), ("1", "-3", 6), ("-1", "-3", 6), ("2", "3", 6),
    ("-2", "3", 6), ("1", "6", 2), ("10", "3", 0), ("5", "2", 0), ("-5", "2", 0),
    ("7", "2", 0), ("1", "8", 2), ("-1", "8", 2), ("1.00", "3.0", 6), ("0.1", "0.03", 3),
    ("1234.5678", "0.001", 1), ("1", "4", 2), ("0", "7", 3), ("-0.001", "7", 2),
    ("1", "0", 2), ("0", "0.00", 2), ("1", "3", -1), ("1", "3", 65), ("1", "3", 64),
    ("9" * 64, "0." + "0" * 31 + "1", 32), ("9" * 64, "0." + "0" * 31 + "1", 31),
    ("1", "9" * 64, 64), ("123456789.123456789", "987654321.987654321", 40),
]

ARITHMETIC_EDGES = [
    ("0", "0"), ("1.5", "1.50"), ("-1.5", "1.5"), ("0.1", "0.2"), ("-0.30", "0.3"),
    ("9" * 64, "9" * 64), ("9" * 64 + "." + "9" * 32, "0." + "0" * 31 + "1"),
    ("-" + "9" * 64, "9" * 64), ("1." + "1" * 32, "1." + "1" * 32),
    ("0." + "0" * 31 + "1", "0." + "0" * 31 + "1"), ("1" + "0" * 63, "1" + "0" * 63),
    ("9" * 64, "1" + "0" * 62 + "1"),
]

POWER_EDGES = [
    ("1.0075", 960, 10), ("1.0075", -960, 10), ("1.0075", 12, 10), ("1.00416667", 360, 12),
    ("1.00416667", -360, 12), ("2", 10, 0), ("2", -10, 10), ("-2", 3, 0), ("-2", -3, 4),
    ("0", 0, 2), ("0", 5, 2), ("0", -1, 2), ("10", 127, 0), ("10", 128, 0), ("10", -64, 64),
    ("10", -65, 64), ("0.5", 3, 3), ("0.5", 3, 2), ("1.1", 2, -1), ("9", 10_000, 0),
    ("9", 10_001, 0), ("1.004167", 585, 10), ("1.004167", -585, 10), ("1.5", 0, 3),
]

ALLOCATE_EDGES = [
    ("100.00", ["1", "1", "1"]), ("-100.00", ["1", "1", "1"]), ("0.05", ["1", "1", "1"]),
    ("10", ["3", "7"]), ("100.00", ["0.5", "0.25", "0.25"]), ("100.00", ["0", "1"]),
    ("100.00", ["33.3", "33.3", "33.4"]), ("0.01", ["1", "1"]), ("0", ["1", "2"]),
    ("1.00", []), ("1.00", ["1", "-1"]), ("1.00", ["0", "0.00"]), ("1234.56", ["1"] * 7),
    ("999.99", ["0.001", "0.002", "0.003"]),
]


def random_decimal(rng: random.Random, integer_digits: int, fraction_digits: int) -> str:
    whole = str(rng.randrange(10 ** rng.randint(1, integer_digits)))
    fraction_length = rng.randint(0, fraction_digits)
    fraction = "".join(rng.choice("0123456789") for _ in range(fraction_length))
    sign = "-" if rng.random() < 0.4 else ""
    return sign + whole + ("." + fraction if fraction else "")


def cases() -> list:
    rng = random.Random(20261031)
    out = []
    for raw in PARSE_EDGES:
        out.append({"op": "parse", "text": raw, **parse(raw)})
    for _ in range(300):
        raw = rng.choice([
            random_decimal(rng, 64, 32),
            random_decimal(rng, 130, 70),
            "".join(rng.choice("0123456789-.e+ ,") for _ in range(rng.randint(0, 12))),
        ])
        out.append({"op": "parse", "text": raw, **parse(raw)})

    pairs = list(ARITHMETIC_EDGES)
    for _ in range(400):
        pairs.append((random_decimal(rng, 64, 32), random_decimal(rng, 64, 32)))
    for a, b in pairs:
        for op in ("add", "subtract", "multiply"):
            out.append({"op": op, "a": a, "b": b, **arithmetic(op, Decimal(a), Decimal(b))})
        out.append({"op": "compare", "a": a, "b": b, **compare(Decimal(a), Decimal(b))})

    products = [
        ("0." + "3" * 64, "10.00", 2), ("0." + "3" * 64, "0." + "3" * 64, 64),
        ("9" * 64, "9" * 64, 0), ("9" * 64 + ".5", "9" * 64, 0), ("2.5", "0.5", 0),
        ("-2.5", "0.5", 0), ("1.005", "1", 2), ("19.99", "0.0725", 2), ("1", "1", 65),
    ]
    for _ in range(300):
        products.append((random_decimal(rng, 40, 64), random_decimal(rng, 30, 64), rng.randint(0, 64)))
    for a, b, scale in products:
        for rounding in ROUNDINGS:
            out.append({"op": "multiply_rounded", "a": a, "b": b, "scale": scale,
                        "rounding": rounding,
                        **multiply_rounded(Decimal(a), Decimal(b), scale, rounding)})

    remainders = [
        ("1000.00", "33.33", 0), ("-1000.00", "33.33", 0), ("1000.00", "-33.33", 0),
        ("-1000.00", "-33.33", 0), ("100.00", "3", 2), ("10", "4", 0), ("10", "5", 0),
        ("1", "0", 0), ("1", "3", -1), ("1", "3", 65), ("1", "0.5", 64), ("1", "0.3", 64),
        ("0.001", "7", 2), ("-0.001", "7", 2), ("0", "7", 3),
        ("9" * 64, "0." + "0" * 31 + "1", 0), ("1", "9" * 64, 64),
    ]
    for _ in range(400):
        remainders.append((random_decimal(rng, 30, 20), random_decimal(rng, 20, 20), rng.randint(0, 30)))
    for a, b, scale in remainders:
        out.append({"op": "divide_with_remainder", "a": a, "b": b, "scale": scale,
                    **divide_with_remainder(Decimal(a), Decimal(b), scale)})

    divisions = list(DIVIDE_EDGES)
    for _ in range(400):
        divisions.append((random_decimal(rng, 40, 20), random_decimal(rng, 30, 20), rng.randint(0, 64)))
    for a, b, scale in divisions:
        for rounding in ROUNDINGS:
            out.append({"op": "divide", "a": a, "b": b, "scale": scale, "rounding": rounding,
                        **divide(Decimal(a), Decimal(b), scale, rounding)})

    roundings = list(ROUND_EDGES)
    for _ in range(300):
        roundings.append((random_decimal(rng, 64, 32), rng.randint(0, 34)))
    for a, scale in roundings:
        for rounding in ROUNDINGS:
            out.append({"op": "round", "a": a, "scale": scale, "rounding": rounding,
                        **round_to(Decimal(a), scale, rounding)})
        out.append({"op": "rescale", "a": a, "scale": scale, **rescale(Decimal(a), scale)})

    powers = list(POWER_EDGES)
    for _ in range(150):
        base = random_decimal(rng, 2, 4)
        powers.append((base, rng.randint(-60, 60), rng.randint(0, 24)))
    for a, exponent, scale in powers:
        for rounding in ROUNDINGS:
            out.append({"op": "power", "a": a, "exponent": exponent, "scale": scale,
                        "rounding": rounding, **power(Decimal(a), exponent, scale, rounding)})

    allocations = list(ALLOCATE_EDGES)
    for _ in range(200):
        amount = random_decimal(rng, 12, 4)
        weights = [random_decimal(rng, 3, 3).lstrip("-") for _ in range(rng.randint(1, 9))]
        allocations.append((amount, weights))
    for amount, weights in allocations:
        out.append({"op": "allocate", "a": amount, "weights": weights,
                    **allocate(Decimal(amount), [Decimal(w) for w in weights])})
    return out


def render() -> str:
    return json.dumps(
        {"generator": "scripts/vectors.py", "oracle": "Python decimal", "cases": cases()},
        indent=None, separators=(",", ":"), ensure_ascii=False,
    ).replace('},{"op"', '},\n{"op"') + "\n"


def main() -> int:
    rendered = render()
    if sys.argv[1:] == ["--check"]:
        if OUTPUT.read_text(encoding="utf-8") != rendered:
            print(f"{OUTPUT} is stale: run scripts/vectors.py", file=sys.stderr)
            return 1
        return 0
    OUTPUT.write_text(rendered, encoding="utf-8")
    print(f"wrote {rendered.count(chr(10))} cases to {OUTPUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
