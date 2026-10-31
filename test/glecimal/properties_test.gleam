//// Laws that hold for every value, checked on generated ones.

import gleam/int
import gleam/list
import gleam/order
import gleam/string
import glecimal.{
  type Decimal, AwayFromZero, Ceiling, Floor, HalfAwayFromZero, HalfEven,
  HalfTowardZero, TowardZero,
}
import glecimal/currency
import glecimal/internal/natural
import glecimal/money
import glecimal/notation
import qcheck

fn digits(count_from: Int, count_to: Int) -> qcheck.Generator(List(Int)) {
  qcheck.generic_list(
    qcheck.bounded_int(0, 9),
    qcheck.bounded_int(count_from, count_to),
  )
}

fn digit_text(digits: List(Int)) -> String {
  digits |> list.map(int.to_string) |> string.concat
}

fn decimal_text(whole: Int, fraction: Int) -> qcheck.Generator(String) {
  use negative, whole, fraction <- qcheck.map3(
    qcheck.bool(),
    digits(1, whole),
    digits(0, fraction),
  )
  let sign = case negative {
    True -> "-"
    False -> ""
  }
  case fraction {
    [] -> sign <> digit_text(whole)
    _ -> sign <> digit_text(whole) <> "." <> digit_text(fraction)
  }
}

fn decimal(whole: Int, fraction: Int) -> qcheck.Generator(Decimal) {
  use text <- qcheck.map(decimal_text(whole, fraction))
  let assert Ok(value) = glecimal.parse(text)
  value
}

fn rounding() -> qcheck.Generator(glecimal.Rounding) {
  qcheck.from_generators(qcheck.return(HalfEven), [
    qcheck.return(HalfAwayFromZero),
    qcheck.return(HalfTowardZero),
    qcheck.return(TowardZero),
    qcheck.return(AwayFromZero),
    qcheck.return(Floor),
    qcheck.return(Ceiling),
  ])
}

pub fn natural_division_identity_test() {
  use #(n, d) <- qcheck.given(qcheck.tuple2(digits(1, 150), digits(1, 80)))
  let n = natural.from_digits(n)
  let d = natural.from_digits(d)
  case natural.is_zero(d) {
    True -> Nil
    False -> {
      let #(q, r) = natural.divide(n, d)
      assert natural.add(natural.multiply(q, d), r) == n
      assert natural.compare(r, d) == order.Lt
    }
  }
}

pub fn natural_text_round_trips_test() {
  use digits <- qcheck.given(digits(1, 150))
  let value = natural.from_digits(digits)
  let text = digit_text(digits)
  let trimmed = case string.replace(text, "0", "") {
    "" -> "0"
    _ -> drop_leading_zeros(text)
  }
  assert natural.to_string(value) == trimmed
}

fn drop_leading_zeros(text: String) -> String {
  case text {
    "0" <> rest -> drop_leading_zeros(rest)
    _ -> text
  }
}

pub fn text_round_trips_test() {
  use value <- qcheck.given(decimal(64, 32))
  assert glecimal.parse(glecimal.to_string(value)) == Ok(value)
}

pub fn computed_values_read_back_test() {
  use #(a, b, scale) <- qcheck.given(qcheck.tuple3(
    decimal(40, 20),
    decimal(30, 20),
    qcheck.bounded_int(0, 64),
  ))
  case glecimal.divide(a, by: b, scale:, rounding: HalfEven) {
    Ok(quotient) -> {
      assert glecimal.parse(glecimal.to_string(quotient)) == Ok(quotient)
    }
    Error(_) -> Nil
  }
}

pub fn multiply_rounded_matches_multiply_then_round_test() {
  use #(a, b, scale, rounding) <- qcheck.given(qcheck.tuple4(
    decimal(30, 32),
    decimal(30, 32),
    qcheck.bounded_int(0, 64),
    rounding(),
  ))
  let assert Ok(product) = glecimal.multiply(a, b)
  assert glecimal.multiply_rounded(a, by: b, scale:, rounding:)
    == glecimal.round(product, scale:, rounding:)
}

pub fn parse_never_crashes_test() {
  use text <- qcheck.given(qcheck.string())
  case glecimal.parse(text) {
    Ok(value) -> {
      assert glecimal.parse(glecimal.to_string(value)) == Ok(value)
    }
    Error(_) -> Nil
  }
}

pub fn addition_commutes_and_subtraction_undoes_it_test() {
  use #(a, b) <- qcheck.given(qcheck.tuple2(decimal(40, 20), decimal(40, 20)))
  let assert Ok(sum) = glecimal.add(a, b)
  assert glecimal.add(b, a) == Ok(sum)
  let assert Ok(back) = glecimal.subtract(sum, b)
  assert glecimal.compare(back, a) == order.Eq
}

pub fn compare_agrees_with_subtraction_test() {
  use #(a, b) <- qcheck.given(qcheck.tuple2(decimal(30, 12), decimal(30, 12)))
  let assert Ok(difference) = glecimal.subtract(a, b)
  assert glecimal.compare(a, b) == glecimal.compare(difference, glecimal.zero())
  assert glecimal.compare(b, a) == order.negate(glecimal.compare(a, b))
}

pub fn division_undoes_multiplication_test() {
  use #(a, b) <- qcheck.given(qcheck.tuple2(decimal(30, 20), decimal(30, 20)))
  case glecimal.is_zero(b) {
    True -> Nil
    False -> {
      let assert Ok(product) = glecimal.multiply(a, b)
      let quotient =
        glecimal.divide(
          product,
          by: b,
          scale: glecimal.scale(a),
          rounding: TowardZero,
        )
      assert quotient == Ok(a)
    }
  }
}

pub fn division_with_remainder_is_exact_test() {
  use #(a, b, scale) <- qcheck.given(qcheck.tuple3(
    decimal(30, 20),
    decimal(20, 20),
    qcheck.bounded_int(0, 30),
  ))
  case glecimal.is_zero(b) {
    True -> Nil
    False -> {
      let assert Ok(#(quotient, remainder)) =
        glecimal.divide_with_remainder(a, by: b, scale:)
      let assert Ok(taken) = glecimal.multiply(quotient, b)
      let assert Ok(whole) = glecimal.add(taken, remainder)
      assert glecimal.compare(whole, a) == order.Eq
      // Smaller than one 10^-scale unit of the divisor, on the dividend's side.
      let assert Ok(unit) = glecimal.from_minor_units(1, scale:)
      let assert Ok(step) = glecimal.multiply(unit, glecimal.absolute_value(b))
      assert glecimal.compare(glecimal.absolute_value(remainder), step)
        == order.Lt
      assert glecimal.is_zero(remainder)
        || glecimal.is_negative(remainder) == glecimal.is_negative(a)
    }
  }
}

pub fn conversion_rounds_the_exact_product_once_test() {
  use #(units, rate, rounding) <- qcheck.given(qcheck.tuple3(
    qcheck.bounded_int(-1_000_000_000, 1_000_000_000),
    decimal(4, 10),
    rounding(),
  ))
  let assert Ok(amount) = money.from_minor_units(units, in: currency.brl)
  let assert Ok(converted) =
    money.convert(amount, to: currency.bhd, at: rate, rounding:)
  assert Ok(money.amount(converted))
    == glecimal.multiply_rounded(
      money.amount(amount),
      by: rate,
      scale: 3,
      rounding:,
    )
  assert money.currency(converted) == currency.bhd
}

pub fn rounding_is_idempotent_and_bracketed_test() {
  use #(value, scale, rounding) <- qcheck.given(qcheck.tuple3(
    decimal(30, 20),
    qcheck.bounded_int(0, 24),
    rounding(),
  ))
  let assert Ok(once) = glecimal.round(value, scale:, rounding:)
  assert glecimal.round(once, scale:, rounding:) == Ok(once)
  let assert Ok(floor) = glecimal.round(value, scale:, rounding: Floor)
  let assert Ok(ceiling) = glecimal.round(value, scale:, rounding: Ceiling)
  assert glecimal.compare(floor, once) != order.Gt
  assert glecimal.compare(once, ceiling) != order.Gt
}

pub fn allocation_adds_up_and_stays_within_one_unit_test() {
  use #(amount, weights) <- qcheck.given(qcheck.tuple2(
    decimal(12, 4),
    qcheck.generic_list(decimal(4, 3), qcheck.bounded_int(1, 12)),
  ))
  let weights = list.map(weights, glecimal.absolute_value)
  let assert Ok(total) = glecimal.sum(weights)
  case glecimal.is_zero(total) {
    True -> Nil
    False -> {
      let assert Ok(parts) = glecimal.allocate(amount, weights:)
      let assert Ok(sum) = glecimal.sum(parts)
      assert sum == amount
      let assert Ok(unit) =
        glecimal.from_minor_units(1, scale: glecimal.scale(amount))
      let assert Ok(limit) = glecimal.multiply(unit, total)
      list.zip(parts, weights)
      |> list.each(fn(pair) {
        // |part × total − amount × weight| < unit × total
        let assert Ok(scaled_part) = glecimal.multiply(pair.0, total)
        let assert Ok(share) = glecimal.multiply(amount, pair.1)
        let assert Ok(gap) = glecimal.subtract(scaled_part, share)
        assert glecimal.compare(glecimal.absolute_value(gap), limit) == order.Lt
      })
    }
  }
}

pub fn power_matches_repeated_multiplication_test() {
  use #(base, exponent) <- qcheck.given(qcheck.tuple2(
    decimal(2, 3),
    qcheck.bounded_int(0, 8),
  ))
  let assert Ok(one) = glecimal.from_int(1)
  let assert Ok(product) =
    list.try_fold(list.repeat(base, exponent), one, glecimal.multiply)
  let assert Ok(power) =
    glecimal.power(
      base,
      exponent:,
      scale: glecimal.scale(product),
      rounding: TowardZero,
    )
  assert power == product
}

pub fn notation_round_trips_test() {
  use value <- qcheck.given(decimal(40, 20))
  [notation.brazilian, notation.english, notation.plain]
  |> list.each(fn(style) {
    assert notation.parse(notation.format(value, style), style) == Ok(value)
  })
}

pub fn money_splits_add_up_test() {
  use #(units, parts) <- qcheck.given(qcheck.tuple2(
    qcheck.bounded_int(-1_000_000_000, 1_000_000_000),
    qcheck.bounded_int(1, 20),
  ))
  let assert Ok(amount) = money.from_minor_units(units, in: currency.brl)
  let assert Ok(shares) = money.split(amount, into: parts)
  assert money.sum(shares, in: currency.brl) == Ok(amount)
}

/// The long division's estimate is clamped to the largest limb when the top
/// limbs alone would suggest more; no vector reaches that branch.
pub fn long_division_clamps_its_estimate_test() {
  let n = natural.from_digits(digits_of("500000000000000000000"))
  let d = natural.from_digits(digits_of("50000000000001"))
  let #(q, r) = natural.divide(n, d)
  assert natural.to_string(q) == "9999999"
  assert natural.add(natural.multiply(q, d), r) == n
}

fn digits_of(text: String) -> List(Int) {
  text
  |> string.to_graphemes
  |> list.map(fn(digit) {
    let assert Ok(value) = int.parse(digit)
    value
  })
}
