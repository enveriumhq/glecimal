# glecimal

[![Package Version](https://img.shields.io/hexpm/v/glecimal)](https://hex.pm/packages/glecimal)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/glecimal/)

**A pure-Gleam exact-decimal library for money and audit.** Parse, compute,
round, allocate, convert and format amounts, with the same 128-digit results on
Erlang and JavaScript. The guide is at [glecimal.com](https://glecimal.com).

- **Exact, or explicit about it.** Addition, subtraction and multiplication are
  exact. Division, rounding and powers take the scale to keep and a named
  rounding; no operation has a default, and nothing rounds silently.
- **No floats, anywhere.** There is no `from_float` and no `to_float`. Decimals
  travel as text: through JSON, PostgreSQL and forms.
- **The same on Erlang and JavaScript.** 128 significant digits on both
  targets, in pure Gleam: no FFI, no NIFs, no BigInt.
- **Bounded.** At most 128 digits and a scale of 64. A result past the bound is
  an error, never a truncated number. Every operation has a stated limit, so
  hostile input costs bounded work.
- **Text that round-trips.** `parse` reads exactly the values a decimal can
  hold, so whatever `to_string` writes reads back unchanged.
- **Money that adds up.** Allocation never loses a cent. `Money` holds the ISO
  4217 currencies at their minor units and never mixes them.
- **Checked against an independent oracle.** 11,658 vectors computed by
  Python's `decimal` module pass on both targets, with property tests beside
  them.

## Installation

```sh
gleam add glecimal
```

glecimal works with Gleam 1.11 or later and `gleam_stdlib` 0.60 or later, on
the Erlang and JavaScript targets. It depends on nothing else.

## Quick start

```gleam
import gleam/result
import glecimal.{type Decimal, HalfEven}

/// Price × quantity, plus tax rounded to cents.
pub fn line_total(
  price: Decimal,
  quantity: Decimal,
  tax_rate: Decimal,
) -> Result(Decimal, glecimal.ArithmeticError) {
  use net <- result.try(glecimal.multiply(price, quantity))
  use tax <- result.try(glecimal.multiply(net, tax_rate))
  use tax <- result.try(glecimal.round(tax, scale: 2, rounding: HalfEven))
  glecimal.add(net, tax)
}

// line_total(19.90, 3, 0.0725) -> Ok(64.03)
```

Values come in through `parse`, which reads the plain form and says exactly
what it refused:

```gleam
glecimal.parse("19.90")  // -> Ok(19.90)
glecimal.parse("19,90")  // -> Error(UnexpectedCharacter(position: 2, character: ","))
glecimal.parse("1e3")    // -> Error(UnexpectedCharacter(position: 1, character: "e"))
```

## Guide

### Scale and equality

A decimal keeps the scale it was written or computed with: `"19.90"` has scale
2 and prints as `19.90`. Addition and subtraction keep the larger scale, and
multiplication adds the scales.

The representation is canonical, so `==` holds exactly when the value and the
scale are both equal: `1.5 == 1.50` is `False`. For numeric equality and order,
use `compare`, which works with `list.sort`:

```gleam
glecimal.compare(one_and_a_half, one_and_a_half_at_scale_2)  // -> Eq
list.sort(amounts, glecimal.compare)
```

`rescale` changes the scale exactly, and refuses to drop a nonzero digit.
`normalize` drops trailing zeros.

What `to_string` writes, `parse` reads: a rate computed to 40 places can be
stored as text and read back unchanged.

### Rounding

Every operation that drops digits takes one of seven roundings, named so they
cannot be misread:

| Rounding | `2.5` | `-2.5` | `2.4` | `-2.4` | Also known as |
|---|---|---|---|---|---|
| `HalfEven` | 2 | -2 | 2 | -2 | banker's rounding; ABNT NBR 5891 |
| `HalfAwayFromZero` | 3 | -3 | 2 | -2 | half up, commercial rounding |
| `HalfTowardZero` | 2 | -2 | 2 | -2 | half down |
| `TowardZero` | 2 | -2 | 2 | -2 | truncation |
| `AwayFromZero` | 3 | -3 | 3 | -3 | up |
| `Floor` | 2 | -3 | 2 | -3 | toward negative infinity |
| `Ceiling` | 3 | -2 | 3 | -2 | toward positive infinity |

```gleam
glecimal.round(amount, scale: 2, rounding: HalfEven)
```

### Division

`divide` computes the exact quotient and rounds it once:

```gleam
glecimal.divide(ten, by: three, scale: 2, rounding: HalfEven)  // -> Ok(3.33)
```

When you need what is left over rather than a rounded quotient,
`divide_with_remainder` truncates the quotient and returns the exact
remainder, so `quotient × divisor + remainder` is the dividend:

```gleam
// How many shares at 33.33 does 1000.00 buy, and what is left?
glecimal.divide_with_remainder(cash, by: price, scale: 0)
// -> Ok(#(30, 0.10))
```

### Products that round once

`multiply` is exact, so its scale is the sum of the operands' scales and can
pass 64. `multiply_rounded` rounds the exact product once, whatever the
operands' scales:

```gleam
// price × a rate computed to 64 places, rounded once to cents
glecimal.multiply_rounded(price, by: rate, scale: 2, rounding: HalfEven)
```

### Powers and interest

`power` computes the exact power and rounds it once, so a compound factor
carries exactly one named rounding. A negative exponent discounts:

```gleam
// BRL 1000.00 at 0.75% a month for 12 months
use factor <- result.try(
  glecimal.power(monthly, exponent: 12, scale: 10, rounding: HalfEven),
)
// factor -> 1.0938068977, and 1000.00 × factor to cents -> 1093.81

use discount <- result.try(
  glecimal.power(monthly, exponent: -12, scale: 10, rounding: HalfEven),
)
// discount -> 0.9142381550, so 1000.00 in a year is worth 914.24 today
```

The exact power is bounded: the base's digits plus its scale, times the
exponent, must not exceed 10,000. Monthly compounding over 80 years at a rate
written like `1.0075` fits, as does a 30-year mortgage at a rate with eight
decimals.

### Allocation

`allocate` splits an amount in proportion to weights, and the parts always add
up to the amount exactly. Each part is its exact share rounded toward zero; the
units left over go one each to the parts with the largest dropped fractions,
the earlier part first on a tie.

```gleam
glecimal.split(hundred, into: 3)
// -> Ok([33.34, 33.33, 33.33])

glecimal.allocate(thousand, weights: [fifty, thirty, twenty])
// -> Ok([500.00, 300.00, 200.00])
```

Allocation errors share `ArithmeticError`, so a split ends a `result.try`
chain without mapping. At most 100,000 parts (`glecimal.max_parts`).

### Money and currencies

`glecimal/currency` holds the 165 ISO 4217 currencies that have minor units,
generated from the list the maintenance agency published on 2026-09-17, as
constants: `currency.brl`, `currency.usd`, `currency.jpy`. `currency.from_code`
reads a code, as `Result(Currency, Nil)`. The table only grows: a code
withdrawn from ISO 4217 keeps a deprecated constant and `from_code` still
reads it, so records written years ago read back. `glecimal/money`
holds an amount at exactly its currency's scale:

```gleam
import glecimal/currency
import glecimal/money

pub fn invoice() -> Result(List(money.Money), money.MoneyError) {
  use price <- result.try(money.from_minor_units(19_990, in: currency.brl))
  use rate <- result.try(
    glecimal.parse("0.0725") |> result.map_error(money.InvalidAmount),
  )
  use tax <- result.try(money.multiply(price, by: rate, rounding: HalfEven))
  use total <- result.try(money.add(price, tax))
  money.split(total, into: 3)
}

// -> Ok([BRL 71.47, BRL 71.46, BRL 71.46])
```

Adding `BRL` to `USD` is `CurrencyMismatch`. `money.new` refuses an amount
with nonzero digits beyond its currency's minor units (`WouldRound`);
`money.new_rounded` takes a rounding, and `money.multiply` rounds the exact
product once. `money.zero(in: currency.brl)` is `BRL 0.00`, and never fails.
`money.to_string` writes the audit form `BRL 214.39`, and `money.parse` reads
it back.

`money.convert` changes currency at a rate, the units of the target currency
per unit of the source, and rounds the exact product once to the target's
minor units:

```gleam
money.convert(price, to: currency.usd, at: rate, rounding: HalfEven)
// BRL 199.90 at 0.1834 -> Ok(USD 36.66)
// the same price in JPY at 27.3851 -> Ok(JPY 5474), in BHD at 0.06903 -> Ok(BHD 13.799)
```

### Display and forms

`glecimal/notation` writes and reads decimals as people do. Parsing is strict:
digit groups have exactly three digits or there are none, and a grouped number
never starts with a zero group. So `0.500` typed into a Brazilian field is
refused, not read as five hundred.

```gleam
import glecimal/notation

notation.format(amount, notation.brazilian)        // -> "1.234.567,89"
notation.format(amount, notation.english)          // -> "1,234,567.89"
notation.parse("1.234,56", notation.brazilian)     // -> Ok(1234.56)
notation.parse("1234,56", notation.brazilian)      // -> Ok(1234.56)
notation.parse("12.34,5", notation.brazilian)      // -> Error(InvalidGrouping(position: 2))
notation.parse("0.500", notation.brazilian)        // -> Error(InvalidGrouping(position: 1))

let assert Ok(swiss) = notation.new(decimal_separator: ".", group_separator: "'")
```

A notation carries separators only: add the currency symbol yourself.
`money.format(price, notation.brazilian)` writes a `Money` amount at its
currency's scale (`1.234,50`); a plain decimal formats at its own scale, so
`rescale` it to two places first.

### JSON

Decimals travel as JSON strings. `glecimal.decoder()` reads them and refuses
numbers, which have already passed through a float. `money.decoder()` reads
`{"amount": "214.39", "currency": "BRL"}`.

```gleam
json.parse(body, decode.at(["total"], glecimal.decoder()))
json.object([#("total", json.string(glecimal.to_string(total)))])
```

### PostgreSQL and Squirrel

Read `numeric` columns as text and pass parameters as text, so no value passes
through a float on the way:

```sql
-- src/billing/sql/invoice_total.sql
select id, total::text as total from billing.invoice where id = $1;

-- src/billing/sql/record_total.sql
update billing.invoice set total = $2::text::numeric where id = $1;
```

Squirrel then generates `total: String`, which the row mapping reads with
`glecimal.parse`, and takes a `String` parameter, which `glecimal.to_string`
fills. PostgreSQL prints a `numeric(14, 2)` column at scale 2, so the scale
survives the round trip. Writing, PostgreSQL silently rounds extra decimals
to the column's scale, half away from zero, so `rescale` (or `round`, naming
the rounding) to the column's scale before writing.

### Lustre

The same code runs in the browser: read a form field with `notation.parse`,
compute with the same functions, and show the result with `notation.format`.
The browser and the server agree to the last digit.

## Limits

| Bound | Value |
|---|---|
| Significant digits | 128 (`glecimal.max_digits`) |
| Scale | 0 to 64 (`glecimal.max_scale`) |
| `parse` | every value within the two bounds above; text up to 130 bytes |
| `allocate`, `split` | 100,000 parts (`glecimal.max_parts`) |
| `from_int`, `to_minor_units` | ±(2^53 − 1), the integers exact on every target |
| `power`: (digits + scale of the base) × exponent | 10,000 |

A result past these bounds is an error, never a truncated number: `Overflow`,
`TooManyDigits`, `PowerTooLarge` or `TooManyParts`.

Additions take well under a microsecond on both targets, and the slowest
operation, a power at its bound, takes tens of milliseconds.

## What the checks hold

- **11,658 vectors** from Python's `decimal` module (`scripts/vectors.py`), an
  oracle independent of this code, cover parsing, arithmetic, comparison,
  rounded products, division and rounding in every mode, division with
  remainder, rescaling, powers and allocation. They pass on Erlang and on
  JavaScript.
- **Property tests** (qcheck): text round-trips, computed values read back,
  rounded products match multiply-then-round, division with remainder is
  exact, conversion rounds once, division undoes multiplication, rounding is idempotent and bracketed by `Floor` and
  `Ceiling`, allocation adds up and stays within one unit of every exact share,
  money splits add up, notation round-trips, and `parse` never crashes on
  arbitrary text.
- **A source ratchet** (`scripts/check-gleam.sh`) holds `src/` at zero crash
  sites (`panic`, `let assert`), floats, FFI and discarded errors.
- **The currency table** is regenerated from the pinned ISO 4217 list and
  compared with the source (`scripts/currencies.py --check`).

`scripts/check.sh` runs all of it, with the formatter and a warnings-as-errors
build on both targets.

## Licence

Apache-2.0.

## About

glecimal is built and maintained by [Enverium](https://www.enverium.com/), a
sustainability reporting platform, for its audit-grade applications.
