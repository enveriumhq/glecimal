//// Exact decimal numbers for money and audit.
////
//// A `Decimal` is an exact value with a scale, the number of digits after
//// the point: `19.90` has scale 2 and stays `19.90`. Addition, subtraction
//// and multiplication are exact. Division, rounding and powers drop digits,
//// so each of them takes the scale to keep and the `Rounding` that decides
//// the last digit. Nothing rounds silently and nothing uses floats.
////
//// Every value is bounded: at most `max_digits` significant digits and a
//// scale of at most `max_scale`. A result beyond the bound is an `Overflow`
//// error, never a truncated number. `parse` reads exactly the values a
//// `Decimal` can hold, so `to_string` and `parse` are inverses, and the work
//// any operation does is bounded by these limits.
////
//// ```gleam
//// import glecimal.{HalfEven}
////
//// pub fn line_total() -> Result(String, glecimal.ArithmeticError) {
////   let assert Ok(price) = glecimal.parse("19.90")
////   let assert Ok(quantity) = glecimal.parse("3")
////   let assert Ok(rate) = glecimal.parse("0.0725")
////   use net <- result.try(glecimal.multiply(price, quantity))
////   use tax <- result.try(glecimal.multiply(net, rate))
////   use tax <- result.try(glecimal.round(tax, scale: 2, rounding: HalfEven))
////   use total <- result.try(glecimal.add(net, tax))
////   Ok(glecimal.to_string(total))
//// }
//// ```
////
//// `==` compares the canonical form, so it holds when the value and the
//// scale are both equal: `1.5` and `1.50` are different under `==` and equal
//// under `compare`. Use `compare` for numeric equality.

import gleam/bit_array
import gleam/bool
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/order.{type Order, Eq, Gt, Lt}
import gleam/result
import gleam/set
import gleam/string
import glecimal/internal/natural.{type Natural}

/// An exact decimal number: a sign, a magnitude and a scale. The
/// representation is canonical, so two values are `==` exactly when their
/// `to_string` texts are equal.
pub opaque type Decimal {
  Decimal(sign: Sign, magnitude: Natural, scale: Int)
}

/// Zero is always `Positive`, so there is no negative zero.
type Sign {
  Positive
  Negative
}

/// How a result that cannot be held exactly at the requested scale chooses
/// its last digit. Every operation that drops digits takes one; none has a
/// default.
pub type Rounding {
  /// To the nearest value; a tie goes to the even digit. Banker's rounding,
  /// the rounding of ABNT NBR 5891 and of IEEE 754 by default.
  HalfEven
  /// To the nearest value; a tie goes away from zero. The common "half up"
  /// (HALF_UP in Java and Python).
  HalfAwayFromZero
  /// To the nearest value; a tie goes toward zero (HALF_DOWN).
  HalfTowardZero
  /// Toward zero: truncation (DOWN).
  TowardZero
  /// Away from zero (UP).
  AwayFromZero
  /// Toward negative infinity.
  Floor
  /// Toward positive infinity.
  Ceiling
}

/// Why `parse` refused a text. Positions count characters from 0.
pub type ParseError {
  /// The text is empty.
  EmptyText
  /// The text is longer than any accepted decimal, checked before scanning.
  TextTooLong(bytes: Int)
  /// A character that the grammar does not allow at this position.
  UnexpectedCharacter(position: Int, character: String)
  /// The text ends where a digit is required, as in `-` or `1.`.
  MissingDigits(position: Int)
  /// More than `max_digits` significant digits; leading zeros do not count.
  TooManyDigits(count: Int)
  /// More than `max_scale` digits after the point.
  TooManyFractionDigits(count: Int)
  /// The group separator at this position starts or ends a group that does
  /// not have three digits; only `glecimal/notation` reads groups.
  InvalidGrouping(position: Int)
}

/// Why an operation has no result. One type serves every operation, so a
/// chain of `use … <- result.try(…)` needs no mapping between steps.
pub type ArithmeticError {
  /// The result has more than `max_digits` digits or a scale above
  /// `max_scale`.
  Overflow
  /// The divisor is zero, or a zero base has a negative exponent.
  DivisionByZero
  /// A requested scale is outside `0` to `max_scale`.
  ScaleOutOfRange(scale: Int)
  /// An exact conversion would have to drop nonzero digits.
  WouldRound
  /// An `Int` outside ±`max_safe_integer`, the integers exact on every target.
  IntegerOutOfRange
  /// The exact power is beyond `max_power_digits`; see `power`.
  PowerTooLarge
  /// `allocate` got no weights, or `split` fewer than one part.
  NoParts
  /// `allocate` or `split` was asked for more than `max_parts` parts.
  TooManyParts(count: Int)
  /// The `allocate` weight at this index (from 0) is negative.
  NegativeWeight(index: Int)
  /// Every `allocate` weight is zero.
  ZeroTotalWeight
}

/// The most significant digits a value holds.
pub const max_digits = 128

/// The largest scale a value holds.
pub const max_scale = 64

/// The largest `Int` that `from_int` and `to_minor_units` accept: 2^53 − 1,
/// the largest integer exact on both Erlang and JavaScript.
pub const max_safe_integer = 9_007_199_254_740_991

/// The bound on `power`: the base's digits plus its scale, times the
/// exponent's absolute value.
pub const max_power_digits = 10_000

/// The most parts `allocate` and `split` produce.
pub const max_parts = 100_000

/// The longest text `parse` scans: the longest canonical text, a sign, 128
/// digits and a point.
const max_text_bytes = 130

// ── Construction and text ──────────────────────────────────────────────────

/// Zero at scale 0.
pub fn zero() -> Decimal {
  Decimal(Positive, [], 0)
}

/// Reads the plain decimal grammar `-?[0-9]+(\.[0-9]+)?` and nothing else: no
/// exponent, grouping, plus sign, spaces or locale forms (`glecimal/notation`
/// reads those). The written scale is kept, so `"1.50"` has scale 2, and
/// `"-0.00"` is `0.00`. It accepts every value a `Decimal` holds, so it reads
/// back anything `to_string` wrote.
///
/// ```gleam
/// glecimal.parse("19.90") |> result.map(glecimal.to_string)
/// // -> Ok("19.90")
/// glecimal.parse("1e3")
/// // -> Error(UnexpectedCharacter(position: 1, character: "e"))
/// ```
pub fn parse(text: String) -> Result(Decimal, ParseError) {
  let bytes = string.byte_size(text)
  use <- bool.guard(bytes > max_text_bytes, Error(TextTooLong(bytes)))
  case bit_array.from_string(text) {
    <<>> -> Error(EmptyText)
    <<45, rest:bytes>> -> parse_unsigned(rest, 1, Negative)
    all -> parse_unsigned(all, 0, Positive)
  }
}

/// Scans bytes: every accepted character is ASCII, so a byte offset is also
/// a character position up to the first refusal.
fn parse_unsigned(
  text: BitArray,
  position: Int,
  sign: Sign,
) -> Result(Decimal, ParseError) {
  let #(whole, after_whole, rest) = scan_digits(text, position, [])
  case whole, rest {
    [], <<>> -> Error(MissingDigits(position))
    [], _ -> unexpected(position, rest)
    _, <<>> -> from_parsed_digits(sign, whole, [])
    _, <<46, fraction_text:bytes>> -> {
      let #(fraction, after_fraction, rest) =
        scan_digits(fraction_text, after_whole + 1, [])
      case fraction, rest {
        [], <<>> -> Error(MissingDigits(after_whole + 1))
        [], _ -> unexpected(after_whole + 1, rest)
        _, <<>> -> from_parsed_digits(sign, whole, fraction)
        _, _ -> unexpected(after_fraction, rest)
      }
    }
    _, _ -> unexpected(after_whole, rest)
  }
}

/// Reads ASCII digits, returning them most significant first, the position
/// after them and the bytes that follow.
fn scan_digits(
  text: BitArray,
  position: Int,
  reversed: List(Int),
) -> #(List(Int), Int, BitArray) {
  case text {
    <<byte, rest:bytes>> if byte >= 48 && byte <= 57 ->
      scan_digits(rest, position + 1, [byte - 48, ..reversed])
    _ -> #(list.reverse(reversed), position, text)
  }
}

/// The refusal for the character that starts `rest`. The bytes before it
/// were ASCII, so `rest` starts on a character boundary.
fn unexpected(position: Int, rest: BitArray) -> Result(a, ParseError) {
  case bit_array.to_string(rest) |> result.try(string.first) {
    Ok(character) -> Error(UnexpectedCharacter(position, character))
    // Unreachable: `rest` is non-empty and starts on a character boundary.
    Error(Nil) -> Error(UnexpectedCharacter(position, ""))
  }
}

/// Builds a parsed value once the grammar holds, checking the bounds.
fn from_parsed_digits(
  sign: Sign,
  whole: List(Int),
  fraction: List(Int),
) -> Result(Decimal, ParseError) {
  let fraction_count = list.length(fraction)
  use <- bool.guard(
    fraction_count > max_scale,
    Error(TooManyFractionDigits(fraction_count)),
  )
  let magnitude = natural.from_digits(list.append(whole, fraction))
  let digits = natural.digit_count(magnitude)
  use <- bool.guard(digits > max_digits, Error(TooManyDigits(digits)))
  Ok(canonical(sign, magnitude, fraction_count))
}

/// The canonical text at the value's scale: digits, a point only when the
/// scale is positive, and a leading `-` only for a negative value. It never
/// uses exponent notation, and `parse` reads every such text back to an `==`
/// value.
pub fn to_string(decimal: Decimal) -> String {
  let body = case decimal.scale {
    0 -> natural.to_string(decimal.magnitude)
    scale -> {
      let #(whole, fraction) =
        natural.divide(decimal.magnitude, natural.power_of_ten(scale))
      natural.to_string(whole)
      <> "."
      <> natural.to_padded_string(fraction, scale)
    }
  }
  case decimal.sign {
    Negative -> "-" <> body
    Positive -> body
  }
}

/// An integer at scale 0. Integers beyond ±`max_safe_integer` are refused,
/// because JavaScript has already rounded them; build those with
/// `parse(int.to_string(n))` on Erlang.
pub fn from_int(n: Int) -> Result(Decimal, ArithmeticError) {
  from_minor_units(n, scale: 0)
}

/// An amount counted in units of `10^-scale`, such as cents:
/// `from_minor_units(1990, scale: 2)` is `19.90`.
pub fn from_minor_units(
  units: Int,
  scale scale: Int,
) -> Result(Decimal, ArithmeticError) {
  use Nil <- result.try(check_scale(scale))
  use <- bool.guard(
    int.absolute_value(units) > max_safe_integer,
    Error(IntegerOutOfRange),
  )
  let sign = case units < 0 {
    True -> Negative
    False -> Positive
  }
  Ok(canonical(sign, natural.from_int(int.absolute_value(units)), scale))
}

/// The value counted in units of `10^-scale`, exactly:
/// `to_minor_units(19.90, scale: 2)` is `1990`. A value with nonzero digits
/// beyond `scale` is `WouldRound` (round it first), and a count beyond
/// ±`max_safe_integer` is `IntegerOutOfRange`.
pub fn to_minor_units(
  decimal: Decimal,
  scale scale: Int,
) -> Result(Int, ArithmeticError) {
  // A count too large to rescale is far beyond the integer range.
  use rescaled <- result.try(case rescale(decimal, scale) {
    Error(Overflow) -> Error(IntegerOutOfRange)
    outcome -> outcome
  })
  use <- bool.guard(
    natural.compare(rescaled.magnitude, natural.from_int(max_safe_integer))
      == Gt,
    Error(IntegerOutOfRange),
  )
  let units = natural.to_int(rescaled.magnitude)
  case rescaled.sign {
    Negative -> Ok(-units)
    Positive -> Ok(units)
  }
}

/// Reads a JSON string (or any dynamic string) with `parse`. Numbers are
/// refused: a JSON number has already passed through a float. A refused text
/// names its reason in the decode error's `expected`.
pub fn decoder() -> decode.Decoder(Decimal) {
  use text <- decode.then(decode.string)
  case parse(text) {
    Ok(decimal) -> decode.success(decimal)
    Error(error) ->
      decode.failure(
        zero(),
        "a decimal (" <> describe_parse_error(error) <> ")",
      )
  }
}

// ── Inspection ─────────────────────────────────────────────────────────────

/// The number of digits after the point.
pub fn scale(decimal: Decimal) -> Int {
  decimal.scale
}

pub fn is_zero(decimal: Decimal) -> Bool {
  natural.is_zero(decimal.magnitude)
}

pub fn is_negative(decimal: Decimal) -> Bool {
  decimal.sign == Negative
}

pub fn is_positive(decimal: Decimal) -> Bool {
  decimal.sign == Positive && !natural.is_zero(decimal.magnitude)
}

/// Compares numeric values, ignoring scale: `1.5` and `1.50` are `Eq`.
pub fn compare(a: Decimal, b: Decimal) -> Order {
  case int.compare(signum(a), signum(b)) {
    Eq -> {
      let #(x, y, _) = align(a, b)
      case a.sign {
        Positive -> natural.compare(x, y)
        Negative -> natural.compare(y, x)
      }
    }
    order -> order
  }
}

fn signum(decimal: Decimal) -> Int {
  case decimal.sign, decimal.magnitude {
    _, [] -> 0
    Positive, _ -> 1
    Negative, _ -> -1
  }
}

/// The smaller value; on a tie, `a`.
pub fn min(a: Decimal, b: Decimal) -> Decimal {
  case compare(a, b) {
    Lt | Eq -> a
    Gt -> b
  }
}

/// The larger value; on a tie, `a`.
pub fn max(a: Decimal, b: Decimal) -> Decimal {
  case compare(a, b) {
    Gt | Eq -> a
    Lt -> b
  }
}

// ── Exact arithmetic ───────────────────────────────────────────────────────

/// `a + b`, exactly, at the larger of the two scales.
pub fn add(a: Decimal, b: Decimal) -> Result(Decimal, ArithmeticError) {
  let #(x, y, scale) = align(a, b)
  case a.sign == b.sign {
    True -> build(a.sign, natural.add(x, y), scale)
    False ->
      case natural.compare(x, y) {
        Lt -> build(b.sign, natural.subtract(y, x), scale)
        Eq | Gt -> build(a.sign, natural.subtract(x, y), scale)
      }
  }
}

/// `a - b`, exactly, at the larger of the two scales.
pub fn subtract(a: Decimal, b: Decimal) -> Result(Decimal, ArithmeticError) {
  add(a, negate(b))
}

/// `a × b`, exactly, at the sum of the two scales. A scale above `max_scale`
/// is `Overflow`: round an operand first.
pub fn multiply(a: Decimal, b: Decimal) -> Result(Decimal, ArithmeticError) {
  build(
    product_sign(a.sign, b.sign),
    natural.multiply(a.magnitude, b.magnitude),
    a.scale + b.scale,
  )
}

/// `a × b` rounded once to `scale`. Unlike `multiply` followed by `round`,
/// the exact product may exceed `max_scale` before it is rounded, so a price
/// times a rate computed to 64 places still has one rounding.
pub fn multiply_rounded(
  a: Decimal,
  by b: Decimal,
  scale scale: Int,
  rounding rounding: Rounding,
) -> Result(Decimal, ArithmeticError) {
  use Nil <- result.try(check_scale(scale))
  let sign = product_sign(a.sign, b.sign)
  natural.multiply(a.magnitude, b.magnitude)
  |> round_magnitude(sign, from: a.scale + b.scale, to: scale, rounding:)
}

/// The exact total, at the largest scale among the values; `sum([])` is 0.
pub fn sum(values: List(Decimal)) -> Result(Decimal, ArithmeticError) {
  list.try_fold(values, zero(), add)
}

/// `-decimal` at the same scale.
pub fn negate(decimal: Decimal) -> Decimal {
  case decimal.sign {
    Positive -> canonical(Negative, decimal.magnitude, decimal.scale)
    Negative -> Decimal(..decimal, sign: Positive)
  }
}

/// `|decimal|` at the same scale.
pub fn absolute_value(decimal: Decimal) -> Decimal {
  Decimal(..decimal, sign: Positive)
}

// ── Rounding and scale ─────────────────────────────────────────────────────

/// `dividend ÷ divisor`, rounded once to `scale` with `rounding`.
///
/// ```gleam
/// glecimal.divide(one, by: three, scale: 6, rounding: HalfEven)
/// // -> Ok(0.333333)
/// ```
pub fn divide(
  dividend: Decimal,
  by divisor: Decimal,
  scale scale: Int,
  rounding rounding: Rounding,
) -> Result(Decimal, ArithmeticError) {
  use Nil <- result.try(check_scale(scale))
  use <- bool.guard(natural.is_zero(divisor.magnitude), Error(DivisionByZero))
  // (m/10^s) / (n/10^t) at scale k is m·10^(t+k) / (n·10^s), rounded.
  let sign = product_sign(dividend.sign, divisor.sign)
  let numerator =
    natural.multiply_power_of_ten(dividend.magnitude, divisor.scale + scale)
  let denominator =
    natural.multiply_power_of_ten(divisor.magnitude, dividend.scale)
  build(sign, rounded_quotient(numerator, denominator, sign, rounding), scale)
}

/// The value at `scale`. Dropping digits applies `rounding`; adding digits
/// appends zeros.
pub fn round(
  decimal: Decimal,
  scale scale: Int,
  rounding rounding: Rounding,
) -> Result(Decimal, ArithmeticError) {
  use Nil <- result.try(check_scale(scale))
  round_magnitude(
    decimal.magnitude,
    decimal.sign,
    from: decimal.scale,
    to: scale,
    rounding:,
  )
}

/// The value at `scale`, exactly: zeros are appended or dropped, and a
/// nonzero digit that would be dropped is `WouldRound`.
pub fn rescale(
  decimal: Decimal,
  scale scale: Int,
) -> Result(Decimal, ArithmeticError) {
  use Nil <- result.try(check_scale(scale))
  case scale >= decimal.scale {
    True -> pad(decimal, scale)
    False -> {
      let #(quotient, remainder) =
        natural.divide(
          decimal.magnitude,
          natural.power_of_ten(decimal.scale - scale),
        )
      case natural.is_zero(remainder) {
        True -> build(decimal.sign, quotient, scale)
        False -> Error(WouldRound)
      }
    }
  }
}

/// The same value at the smallest scale that holds it exactly: `2.500`
/// becomes `2.5`, and `0.00` becomes `0`.
pub fn normalize(decimal: Decimal) -> Decimal {
  case decimal.scale, natural.divide(decimal.magnitude, [10]) {
    0, _ -> decimal
    scale, #(quotient, []) ->
      normalize(canonical(decimal.sign, quotient, scale - 1))
    _, _ -> decimal
  }
}

/// `base^exponent`, computed exactly and rounded once to `scale`, so a
/// compound factor carries exactly one named rounding. A negative exponent
/// discounts: `power(1.01, exponent: -12, …)` is `1 ÷ 1.01^12`. `0^0` is 1.
///
/// The exact power is bounded: when the base's digits plus its scale, times
/// `|exponent|`, exceed `max_power_digits`, the result is `PowerTooLarge`.
/// Monthly compounding over 80 years (960 periods) at a rate written like
/// `1.0075` fits, as does a 30-year mortgage (360 periods) at a rate with
/// eight decimals.
pub fn power(
  base: Decimal,
  exponent exponent: Int,
  scale scale: Int,
  rounding rounding: Rounding,
) -> Result(Decimal, ArithmeticError) {
  use Nil <- result.try(check_scale(scale))
  // The exponent alone is checked first: on JavaScript an `Int` parsed from
  // a long text can be infinite, and only this comparison refuses it.
  let exponent_size = int.absolute_value(exponent)
  use <- bool.guard(
    !{ exponent_size <= max_power_digits },
    Error(PowerTooLarge),
  )
  let size =
    exponent_size * { natural.digit_count(base.magnitude) + base.scale }
  use <- bool.guard(size > max_power_digits, Error(PowerTooLarge))
  let sign = case base.sign, int.is_odd(exponent) {
    Negative, True -> Negative
    Negative, False -> Positive
    Positive, _ -> Positive
  }
  case exponent >= 0, natural.is_zero(base.magnitude) {
    False, True -> Error(DivisionByZero)
    True, _ -> {
      // (m/10^s)^e = m^e / 10^(s·e)
      natural.power(base.magnitude, exponent)
      |> round_magnitude(
        sign,
        from: base.scale * exponent,
        to: scale,
        rounding:,
      )
    }
    False, False -> {
      // (m/10^s)^-k = 10^(s·k) / m^k
      let k = -exponent
      let numerator = natural.power_of_ten(base.scale * k + scale)
      let denominator = natural.power(base.magnitude, k)
      build(
        sign,
        rounded_quotient(numerator, denominator, sign, rounding),
        scale,
      )
    }
  }
}

// ── Allocation ─────────────────────────────────────────────────────────────

/// Splits `amount` in proportion to `weights`, at the amount's scale, so the
/// parts always add up to the amount exactly. Each part is its exact share
/// rounded toward zero; the units left over go one each to the parts with
/// the largest dropped fractions, the earlier part first on a tie. Every
/// part is within one unit (`10^-scale`) of its exact share. At most
/// `max_parts` weights are accepted.
///
/// ```gleam
/// glecimal.allocate(hundred, weights: [one, one, one])
/// // -> Ok([33.34, 33.33, 33.33])
/// ```
pub fn allocate(
  amount: Decimal,
  weights weights: List(Decimal),
) -> Result(List(Decimal), ArithmeticError) {
  use Nil <- result.try(check_weights(weights, 0))
  let weight_scale =
    list.fold(weights, 0, fn(largest, weight) { int.max(largest, weight.scale) })
  let units =
    list.map(weights, fn(weight) {
      natural.multiply_power_of_ten(
        weight.magnitude,
        weight_scale - weight.scale,
      )
    })
  case list.fold(units, [], natural.add) {
    [] -> Error(ZeroTotalWeight)
    total -> Ok(distribute(amount, units, total))
  }
}

/// Splits `amount` into `parts` equal shares, as `allocate` does with equal
/// weights.
pub fn split(
  amount: Decimal,
  into parts: Int,
) -> Result(List(Decimal), ArithmeticError) {
  use <- bool.guard(parts < 1, Error(NoParts))
  // Written so that an infinite `Int` on JavaScript is refused too.
  use <- bool.guard(!{ parts <= max_parts }, Error(TooManyParts(parts)))
  allocate(amount, weights: list.repeat(Decimal(Positive, [1], 0), parts))
}

fn check_weights(
  weights: List(Decimal),
  index: Int,
) -> Result(Nil, ArithmeticError) {
  case weights, index {
    [], 0 -> Error(NoParts)
    [], _ -> Ok(Nil)
    _, _ if index >= max_parts ->
      Error(TooManyParts(index + list.length(weights)))
    [weight, ..rest], _ ->
      case weight.sign {
        Negative -> Error(NegativeWeight(index))
        Positive -> check_weights(rest, index + 1)
      }
  }
}

fn distribute(
  amount: Decimal,
  weights: List(Natural),
  total: Natural,
) -> List(Decimal) {
  let shares =
    list.map(weights, fn(weight) {
      natural.divide(natural.multiply(amount.magnitude, weight), total)
    })
  let floored =
    list.fold(shares, [], fn(acc, share) { natural.add(acc, share.0) })
  // Each share loses less than one unit, so the leftover is a small count.
  let leftover = natural.to_int(natural.subtract(amount.magnitude, floored))
  let receiving =
    shares
    |> list.index_map(fn(share, index) { #(index, share.1) })
    |> list.sort(fn(a, b) {
      case natural.compare(b.1, a.1) {
        Eq -> int.compare(a.0, b.0)
        order -> order
      }
    })
    |> list.take(leftover)
    |> list.map(fn(ranked) { ranked.0 })
    |> set.from_list
  list.index_map(shares, fn(share, index) {
    let magnitude = case set.contains(receiving, index) {
      True -> natural.add(share.0, [1])
      False -> share.0
    }
    canonical(amount.sign, magnitude, amount.scale)
  })
}

// ── Messages ───────────────────────────────────────────────────────────────

/// A sentence for logs and messages.
pub fn describe_parse_error(error: ParseError) -> String {
  case error {
    EmptyText -> "the text is empty"
    TextTooLong(bytes) ->
      "the text has "
      <> int.to_string(bytes)
      <> " bytes, more than any accepted decimal"
    UnexpectedCharacter(position, character) ->
      "unexpected \""
      <> character
      <> "\" at position "
      <> int.to_string(position)
    MissingDigits(position) ->
      "a digit is required at position " <> int.to_string(position)
    TooManyDigits(count) ->
      int.to_string(count)
      <> " significant digits, at most "
      <> int.to_string(max_digits)
    TooManyFractionDigits(count) ->
      int.to_string(count)
      <> " digits after the point, at most "
      <> int.to_string(max_scale)
    InvalidGrouping(position) ->
      "the digit group at position "
      <> int.to_string(position)
      <> " does not have three digits"
  }
}

/// A sentence for logs and messages.
pub fn describe_arithmetic_error(error: ArithmeticError) -> String {
  case error {
    Overflow ->
      "the result exceeds "
      <> int.to_string(max_digits)
      <> " digits or scale "
      <> int.to_string(max_scale)
    DivisionByZero -> "division by zero"
    ScaleOutOfRange(scale) ->
      "scale "
      <> int.to_string(scale)
      <> " is outside 0 to "
      <> int.to_string(max_scale)
    WouldRound -> "the conversion would drop nonzero digits"
    IntegerOutOfRange ->
      "the integer is beyond ±" <> int.to_string(max_safe_integer)
    PowerTooLarge ->
      "the exact power exceeds " <> int.to_string(max_power_digits) <> " digits"
    NoParts -> "an amount splits into one part or more"
    TooManyParts(count) ->
      int.to_string(count) <> " parts, at most " <> int.to_string(max_parts)
    NegativeWeight(index) ->
      "the weight at index " <> int.to_string(index) <> " is negative"
    ZeroTotalWeight -> "every weight is zero"
  }
}

// ── Internals ──────────────────────────────────────────────────────────────

/// Zero is always positive.
fn canonical(sign: Sign, magnitude: Natural, scale: Int) -> Decimal {
  case magnitude {
    [] -> Decimal(Positive, [], scale)
    _ -> Decimal(sign, magnitude, scale)
  }
}

/// Checks the bounds and builds a result.
fn build(
  sign: Sign,
  magnitude: Natural,
  scale: Int,
) -> Result(Decimal, ArithmeticError) {
  case scale > max_scale || natural.digit_count(magnitude) > max_digits {
    True -> Error(Overflow)
    False -> Ok(canonical(sign, magnitude, scale))
  }
}

fn check_scale(scale: Int) -> Result(Nil, ArithmeticError) {
  case scale < 0 || scale > max_scale {
    True -> Error(ScaleOutOfRange(scale))
    False -> Ok(Nil)
  }
}

/// A magnitude at scale `from`, rounded or padded to scale `to`.
fn round_magnitude(
  magnitude: Natural,
  sign: Sign,
  from exact_scale: Int,
  to scale: Int,
  rounding rounding: Rounding,
) -> Result(Decimal, ArithmeticError) {
  case exact_scale <= scale {
    True ->
      build(
        sign,
        natural.multiply_power_of_ten(magnitude, scale - exact_scale),
        scale,
      )
    False ->
      build(
        sign,
        rounded_quotient(
          magnitude,
          natural.power_of_ten(exact_scale - scale),
          sign,
          rounding,
        ),
        scale,
      )
  }
}

fn pad(decimal: Decimal, scale: Int) -> Result(Decimal, ArithmeticError) {
  build(
    decimal.sign,
    natural.multiply_power_of_ten(decimal.magnitude, scale - decimal.scale),
    scale,
  )
}

/// Both magnitudes at the larger scale, and that scale.
fn align(a: Decimal, b: Decimal) -> #(Natural, Natural, Int) {
  case int.compare(a.scale, b.scale) {
    Lt -> #(
      natural.multiply_power_of_ten(a.magnitude, b.scale - a.scale),
      b.magnitude,
      b.scale,
    )
    Gt -> #(
      a.magnitude,
      natural.multiply_power_of_ten(b.magnitude, a.scale - b.scale),
      a.scale,
    )
    Eq -> #(a.magnitude, b.magnitude, a.scale)
  }
}

fn product_sign(a: Sign, b: Sign) -> Sign {
  case a == b {
    True -> Positive
    False -> Negative
  }
}

/// `numerator ÷ denominator` rounded to an integer with `rounding`, where
/// `sign` is the sign of the exact quotient.
fn rounded_quotient(
  numerator: Natural,
  denominator: Natural,
  sign: Sign,
  rounding: Rounding,
) -> Natural {
  let #(quotient, remainder) = natural.divide(numerator, denominator)
  case natural.is_zero(remainder) {
    True -> quotient
    False ->
      case away_from_zero(rounding, sign, quotient, remainder, denominator) {
        True -> natural.add(quotient, [1])
        False -> quotient
      }
  }
}

/// Whether a nonzero remainder moves the truncated quotient one unit away
/// from zero.
fn away_from_zero(
  rounding: Rounding,
  sign: Sign,
  quotient: Natural,
  remainder: Natural,
  denominator: Natural,
) -> Bool {
  case rounding {
    TowardZero -> False
    AwayFromZero -> True
    Floor -> sign == Negative
    Ceiling -> sign == Positive
    HalfEven ->
      past_half(remainder, denominator, tie: !natural.is_even(quotient))
    HalfAwayFromZero -> past_half(remainder, denominator, tie: True)
    HalfTowardZero -> past_half(remainder, denominator, tie: False)
  }
}

fn past_half(remainder: Natural, denominator: Natural, tie tie: Bool) -> Bool {
  case natural.compare(natural.add(remainder, remainder), denominator) {
    Gt -> True
    Lt -> False
    Eq -> tie
  }
}
