//// The examples on glecimal.com (site/index.html), compiled and checked.
//// Keep each test in step with the snippet it mirrors.

import gleam/float
import gleam/json
import gleam/list
import gleam/order
import gleam/result
import glecimal.{
  type Decimal, AwayFromZero, Ceiling, Floor, HalfAwayFromZero, HalfEven,
  HalfTowardZero, InvalidGrouping, TowardZero, UnexpectedCharacter,
}
import glecimal/currency
import glecimal/money.{CurrencyMismatch}
import glecimal/notation

fn d(text: String) -> Decimal {
  let assert Ok(value) = glecimal.parse(text)
  value
}

fn text(outcome: Result(Decimal, e)) -> Result(String, e) {
  result.map(outcome, glecimal.to_string)
}

pub fn the_opening_sum_test() {
  assert glecimal.add(d("0.1"), d("0.2")) |> text == Ok("0.3")
  assert float.to_string(0.1 +. 0.2) == "0.30000000000000004"
}

pub fn a_decimal_keeps_its_scale_test() {
  let price = d("19.90")
  assert glecimal.to_string(price) == "19.90"
  assert glecimal.parse("19,90") == Error(UnexpectedCharacter(2, ","))
  assert glecimal.add(price, d("0.1")) |> text == Ok("20.00")
  assert glecimal.multiply(price, d("3")) |> text == Ok("59.70")
  assert d("19.9") != price
  assert glecimal.compare(d("19.9"), price) == order.Eq
}

pub fn every_rounding_has_a_name_test() {
  let row = fn(rounding) {
    ["2.5", "-2.5", "2.4"]
    |> list.map(fn(value) {
      let assert Ok(rounded) = glecimal.round(d(value), scale: 0, rounding:)
      glecimal.to_string(rounded)
    })
  }
  assert row(HalfEven) == ["2", "-2", "2"]
  assert row(HalfAwayFromZero) == ["3", "-3", "2"]
  assert row(HalfTowardZero) == ["2", "-2", "2"]
  assert row(TowardZero) == ["2", "-2", "2"]
  assert row(AwayFromZero) == ["3", "-3", "3"]
  assert row(Floor) == ["2", "-3", "2"]
  assert row(Ceiling) == ["3", "-2", "3"]
}

pub fn one_rounding_per_answer_test() {
  assert glecimal.divide(d("10"), by: d("3"), scale: 2, rounding: HalfEven)
    |> text
    == Ok("3.33")
  assert glecimal.multiply_rounded(
      d("19.99"),
      by: d("0.0725"),
      scale: 2,
      rounding: HalfEven,
    )
    |> text
    == Ok("1.45")
  assert glecimal.power(
      d("1.0075"),
      exponent: 12,
      scale: 10,
      rounding: HalfEven,
    )
    |> text
    == Ok("1.0938068977")
}

pub fn sharing_out_money_test() {
  assert glecimal.split(d("100.00"), into: 3)
    |> result.map(list.map(_, glecimal.to_string))
    == Ok(["33.34", "33.33", "33.33"])
  assert glecimal.allocate(d("1000.00"), weights: [d("50"), d("30"), d("20")])
    |> result.map(list.map(_, glecimal.to_string))
    == Ok(["500.00", "300.00", "200.00"])
  assert glecimal.divide_with_remainder(d("1000.00"), by: d("33.33"), scale: 0)
    |> result.map(fn(pair) {
      #(glecimal.to_string(pair.0), glecimal.to_string(pair.1))
    })
    == Ok(#("30", "0.10"))
}

pub fn money_and_currencies_test() {
  let assert Ok(reais) = money.from_minor_units(1000, in: currency.brl)
  let assert Ok(dollars) = money.from_minor_units(1000, in: currency.usd)
  assert money.add(reais, dollars)
    == Error(CurrencyMismatch(expected: currency.brl, found: currency.usd))
  let assert Ok(price) = money.from_minor_units(19_990, in: currency.brl)
  assert money.convert(
      price,
      to: currency.usd,
      at: d("0.1834"),
      rounding: HalfEven,
    )
    |> result.map(money.to_string)
    == Ok("USD 36.66")
  assert money.to_string(money.zero(in: currency.jpy)) == "JPY 0"
  assert money.from_minor_units(1050, in: currency.bhd)
    |> result.map(money.to_string)
    == Ok("BHD 1.050")
  assert list.length(currency.listed()) == 165
}

pub fn numbers_people_type_and_read_test() {
  assert notation.format(d("1234567.89"), notation.brazilian) == "1.234.567,89"
  assert notation.parse("1.234,56", notation.brazilian) |> text == Ok("1234.56")
  assert notation.parse("0.500", notation.brazilian)
    == Error(InvalidGrouping(1))
}

pub fn at_the_edges_test() {
  assert json.parse("\"214.39\"", glecimal.decoder()) |> text == Ok("214.39")
  assert json.parse("214.39", glecimal.decoder()) |> result.is_error
}

pub fn limits_test() {
  assert glecimal.max_digits == 128
  assert glecimal.max_scale == 64
  assert glecimal.max_parts == 100_000
  assert glecimal.max_power_digits == 10_000
  assert glecimal.max_safe_integer == 9_007_199_254_740_991
  assert glecimal.parse("1e3") == Error(UnexpectedCharacter(1, "e"))
}
