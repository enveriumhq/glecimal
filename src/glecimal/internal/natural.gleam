//// Unsigned integers of any size, held as base-10^7 limbs, least significant
//// first, with no zero limb at the most significant end: zero is the empty
//// list. Every intermediate of the limb arithmetic stays below
//// 10^14 + 10^7, and `from_int` and `to_int` stay within 2^53 − 1, so the
//// arithmetic is exact on JavaScript, where an `Int` is a float64, and
//// identical on Erlang.
////
//// Functions take canonical values and return canonical values; nothing
//// outside this module builds a limb list.

import gleam/int
import gleam/list
import gleam/order.{type Order, Eq, Gt, Lt}
import gleam/string

/// A canonical limb list.
pub type Natural =
  List(Int)

const base = 10_000_000

const base_digits = 7

/// Quotient and remainder of a non-negative `n` by a positive `d`. JavaScript
/// divides through floats, so the quotient is taken of an exact multiple of
/// `d`, which divides exactly.
fn div_rem(n: Int, d: Int) -> #(Int, Int) {
  let remainder = n % d
  #({ n - remainder } / d, remainder)
}

/// A non-negative `Int` as a natural.
pub fn from_int(n: Int) -> Natural {
  from_int_loop(n, [])
  |> list.reverse
}

fn from_int_loop(n: Int, limbs: List(Int)) -> List(Int) {
  case n {
    0 -> limbs
    _ -> {
      let #(quotient, remainder) = div_rem(n, base)
      from_int_loop(quotient, [remainder, ..limbs])
    }
  }
}

/// The value as an `Int`. Callers bound it first: the result is exact only
/// below 2^53 on JavaScript.
pub fn to_int(a: Natural) -> Int {
  list.fold_right(a, 0, fn(acc, limb) { acc * base + limb })
}

/// Decimal digits, most significant first, each 0 to 9.
pub fn from_digits(most_significant_first: List(Int)) -> Natural {
  most_significant_first
  |> list.reverse
  |> list.sized_chunk(base_digits)
  |> list.map(fn(chunk) {
    list.fold_right(chunk, 0, fn(acc, digit) { acc * 10 + digit })
  })
  |> trim
}

/// The decimal text: digits only, "0" for zero.
pub fn to_string(a: Natural) -> String {
  case list.reverse(a) {
    [] -> "0"
    [top, ..rest] ->
      int.to_string(top) <> string.concat(list.map(rest, padded_limb))
  }
}

/// The decimal text left-padded with zeros to `width` digits; zero is all
/// zeros. Counting digits avoids the grapheme functions, which are slow on
/// JavaScript.
pub fn to_padded_string(a: Natural, width: Int) -> String {
  case a {
    [] -> string.repeat("0", width)
    _ -> string.repeat("0", width - digit_count(a)) <> to_string(a)
  }
}

fn padded_limb(limb: Int) -> String {
  string.repeat("0", base_digits - small_digit_count(limb))
  <> int.to_string(limb)
}

pub fn is_zero(a: Natural) -> Bool {
  a == []
}

pub fn is_even(a: Natural) -> Bool {
  case a {
    [] -> True
    [low, ..] -> low % 2 == 0
  }
}

/// The number of decimal digits; zero has none.
pub fn digit_count(a: Natural) -> Int {
  case list.reverse(a) {
    [] -> 0
    [top, ..rest] -> list.length(rest) * base_digits + small_digit_count(top)
  }
}

fn small_digit_count(limb: Int) -> Int {
  case limb {
    _ if limb < 10 -> 1
    _ if limb < 100 -> 2
    _ if limb < 1000 -> 3
    _ if limb < 10_000 -> 4
    _ if limb < 100_000 -> 5
    _ if limb < 1_000_000 -> 6
    _ -> 7
  }
}

pub fn compare(a: Natural, b: Natural) -> Order {
  case int.compare(list.length(a), list.length(b)) {
    Eq -> compare_limbs(a, b, Eq)
    order -> order
  }
}

/// Walks up from the least significant limb; a difference in a higher limb
/// overrides what the lower limbs decided.
fn compare_limbs(a: List(Int), b: List(Int), lower: Order) -> Order {
  case a, b {
    [x, ..xs], [y, ..ys] ->
      compare_limbs(xs, ys, case int.compare(x, y) {
        Eq -> lower
        order -> order
      })
    _, _ -> lower
  }
}

pub fn add(a: Natural, b: Natural) -> Natural {
  add_loop(a, b, 0, [])
}

fn add_loop(a: List(Int), b: List(Int), carry: Int, acc: List(Int)) -> Natural {
  case a, b {
    [], [] ->
      case carry {
        0 -> list.reverse(acc)
        _ -> list.reverse([carry, ..acc])
      }
    [x, ..xs], [] -> add_step(x + carry, xs, [], acc)
    [], [y, ..ys] -> add_step(y + carry, [], ys, acc)
    [x, ..xs], [y, ..ys] -> add_step(x + y + carry, xs, ys, acc)
  }
}

fn add_step(
  total: Int,
  xs: List(Int),
  ys: List(Int),
  acc: List(Int),
) -> Natural {
  case total >= base {
    True -> add_loop(xs, ys, 1, [total - base, ..acc])
    False -> add_loop(xs, ys, 0, [total, ..acc])
  }
}

/// `a - b`, where `a >= b`.
pub fn subtract(a: Natural, b: Natural) -> Natural {
  subtract_loop(a, b, 0, [])
}

/// `acc` holds the result most significant first, so its leading zeros drop
/// before the final reverse.
fn subtract_loop(
  a: List(Int),
  b: List(Int),
  borrow: Int,
  acc: List(Int),
) -> Natural {
  case a, b {
    [], _ ->
      acc
      |> list.drop_while(fn(limb) { limb == 0 })
      |> list.reverse
    [x, ..xs], [] -> subtract_step(x - borrow, xs, [], acc)
    [x, ..xs], [y, ..ys] -> subtract_step(x - y - borrow, xs, ys, acc)
  }
}

fn subtract_step(
  difference: Int,
  xs: List(Int),
  ys: List(Int),
  acc: List(Int),
) -> Natural {
  case difference < 0 {
    True -> subtract_loop(xs, ys, 1, [difference + base, ..acc])
    False -> subtract_loop(xs, ys, 0, [difference, ..acc])
  }
}

/// `a * m`, where `0 <= m < 10^7`.
fn multiply_small(a: Natural, m: Int) -> Natural {
  case m {
    0 -> []
    _ -> multiply_small_loop(a, m, 0, [])
  }
}

fn multiply_small_loop(
  a: List(Int),
  m: Int,
  carry: Int,
  acc: List(Int),
) -> Natural {
  case a {
    [] ->
      case carry {
        0 -> list.reverse(acc)
        _ -> list.reverse([carry, ..acc])
      }
    [x, ..xs] -> {
      let #(high, low) = div_rem(x * m + carry, base)
      multiply_small_loop(xs, m, high, [low, ..acc])
    }
  }
}

pub fn multiply(a: Natural, b: Natural) -> Natural {
  case list.length(a) < list.length(b) {
    True -> multiply_loop(b, a, 0, [])
    False -> multiply_loop(a, b, 0, [])
  }
}

/// Schoolbook multiplication, one limb of the shorter operand at a time.
fn multiply_loop(
  a: Natural,
  b: List(Int),
  shift: Int,
  acc: Natural,
) -> Natural {
  case b {
    [] -> acc
    [y, ..ys] ->
      multiply_loop(
        a,
        ys,
        shift + 1,
        add(acc, shift_limbs(multiply_small(a, y), shift)),
      )
  }
}

/// `a * 10^(7 * limbs)`.
fn shift_limbs(a: Natural, limbs: Int) -> Natural {
  case a {
    [] -> []
    _ -> list.append(list.repeat(0, limbs), a)
  }
}

/// `a * 10^k`, where `k >= 0`.
pub fn multiply_power_of_ten(a: Natural, k: Int) -> Natural {
  let #(limbs, digits) = div_rem(k, base_digits)
  shift_limbs(multiply_small(a, small_power_of_ten(digits)), limbs)
}

/// `10^k`, where `k >= 0`.
pub fn power_of_ten(k: Int) -> Natural {
  multiply_power_of_ten([1], k)
}

fn small_power_of_ten(k: Int) -> Int {
  case k {
    0 -> 1
    1 -> 10
    2 -> 100
    3 -> 1000
    4 -> 10_000
    5 -> 100_000
    _ -> 1_000_000
  }
}

/// `a^exponent` by repeated squaring, where `exponent >= 0`; `0^0` is 1.
pub fn power(a: Natural, exponent: Int) -> Natural {
  power_loop(a, exponent, [1])
}

fn power_loop(a: Natural, exponent: Int, acc: Natural) -> Natural {
  case exponent {
    0 -> acc
    _ -> {
      let acc = case int.is_odd(exponent) {
        True -> multiply(acc, a)
        False -> acc
      }
      case exponent / 2 {
        0 -> acc
        half -> power_loop(multiply(a, a), half, acc)
      }
    }
  }
}

/// Quotient and remainder of `a` by a nonzero `b`. A zero `b` returns a zero
/// quotient and `a` as the remainder; callers refuse it before.
pub fn divide(a: Natural, b: Natural) -> #(Natural, Natural) {
  case b {
    [] -> #([], a)
    [d] -> {
      let #(quotient, remainder) = divide_small(a, d)
      #(quotient, from_int(remainder))
    }
    _ ->
      case compare(a, b) {
        Lt -> #([], a)
        Eq | Gt -> divide_long(a, b)
      }
  }
}

/// `a` divided by `0 < d < 10^7`, most significant limb first.
fn divide_small(a: Natural, d: Int) -> #(Natural, Int) {
  divide_small_loop(list.reverse(a), d, 0, [])
}

/// The first quotient limbs produced are the most significant, so zeros are
/// skipped until the first nonzero one.
fn divide_small_loop(
  most_significant_first: List(Int),
  d: Int,
  remainder: Int,
  acc: List(Int),
) -> #(Natural, Int) {
  case most_significant_first {
    [] -> #(acc, remainder)
    [x, ..xs] -> {
      let #(digit, remainder) = div_rem(remainder * base + x, d)
      case acc, digit {
        [], 0 -> divide_small_loop(xs, d, remainder, [])
        _, _ -> divide_small_loop(xs, d, remainder, [digit, ..acc])
      }
    }
  }
}

/// Long division (Knuth's algorithm D). Both operands are scaled so the
/// divisor's top limb is at least half the base; each quotient limb is then
/// estimated from the top limbs and corrected at most twice.
fn divide_long(a: Natural, b: Natural) -> #(Natural, Natural) {
  let factor = div_rem(base, top_limb(b) + 1).0
  let divisor = multiply_small(b, factor)
  let #(quotient, scaled_remainder) =
    divide_long_loop(
      list.reverse(multiply_small(a, factor)),
      divisor,
      list.length(divisor),
      top_limb(divisor),
      [],
      [],
    )
  #(quotient, divide_small(scaled_remainder, factor).0)
}

fn top_limb(a: Natural) -> Int {
  case list.reverse(a) {
    [top, ..] -> top
    [] -> 0
  }
}

fn divide_long_loop(
  most_significant_first: List(Int),
  divisor: Natural,
  divisor_limbs: Int,
  divisor_top: Int,
  remainder: Natural,
  acc: List(Int),
) -> #(Natural, Natural) {
  case most_significant_first {
    [] -> #(acc, remainder)
    [x, ..xs] -> {
      let remainder = case remainder, x {
        [], 0 -> []
        _, _ -> [x, ..remainder]
      }
      let #(digit, product) =
        quotient_limb(remainder, divisor, divisor_limbs, divisor_top)
      let remainder = subtract(remainder, product)
      let acc = case acc, digit {
        [], 0 -> []
        _, _ -> [digit, ..acc]
      }
      divide_long_loop(xs, divisor, divisor_limbs, divisor_top, remainder, acc)
    }
  }
}

/// The quotient limb of `remainder / divisor`, where `remainder < divisor *
/// 10^7`, with `divisor * limb`. The estimate from the top limbs is never too
/// small, so correcting it only counts down.
fn quotient_limb(
  remainder: Natural,
  divisor: Natural,
  divisor_limbs: Int,
  divisor_top: Int,
) -> #(Int, Natural) {
  case compare(remainder, divisor) {
    Lt -> #(0, [])
    Eq | Gt -> {
      let top = case list.drop(remainder, divisor_limbs - 1) {
        [high] -> high
        [low, high, ..] -> high * base + low
        [] -> 0
      }
      let estimate = int.min(div_rem(top, divisor_top).0, base - 1)
      correct_limb(estimate, remainder, divisor)
    }
  }
}

fn correct_limb(
  estimate: Int,
  remainder: Natural,
  divisor: Natural,
) -> #(Int, Natural) {
  let product = multiply_small(divisor, estimate)
  case compare(product, remainder) {
    Gt -> correct_limb(estimate - 1, remainder, divisor)
    Lt | Eq -> #(estimate, product)
  }
}

/// Drops zero limbs at the most significant end.
fn trim(a: List(Int)) -> Natural {
  a
  |> list.reverse
  |> list.drop_while(fn(limb) { limb == 0 })
  |> list.reverse
}
