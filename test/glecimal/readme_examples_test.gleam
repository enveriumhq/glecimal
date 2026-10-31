//// The README's examples, compiled and checked. Keep each test in step with
//// the snippet it mirrors.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/order
import gleam/result
import glecimal.{
  type Decimal, AwayFromZero, Ceiling, Floor, HalfAwayFromZero, HalfEven,
  HalfTowardZero, InvalidGrouping, TowardZero, UnexpectedCharacter,
}
import glecimal/currency
import glecimal/money
import glecimal/notation

fn d(text: String) -> Decimal {
  let assert Ok(value) = glecimal.parse(text)
  value
}

fn texts(outcome: Result(List(Decimal), e)) -> Result(List(String), e) {
  result.map(outcome, list.map(_, glecimal.to_string))
}

// ── Quick start ────────────────────────────────────────────────────────────

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

pub fn quick_start_test() {
  assert line_total(d("19.90"), d("3"), d("0.0725"))
    |> result.map(glecimal.to_string)
    == Ok("64.03")
  assert glecimal.parse("19.90") |> result.map(glecimal.to_string)
    == Ok("19.90")
  assert glecimal.parse("19,90") == Error(UnexpectedCharacter(2, ","))
  assert glecimal.parse("1e3") == Error(UnexpectedCharacter(1, "e"))
}

// ── Guide ──────────────────────────────────────────────────────────────────

pub fn scale_and_equality_test() {
  assert d("1.5") != d("1.50")
  assert glecimal.compare(d("1.5"), d("1.50")) == order.Eq
  assert list.sort([d("2"), d("-1.5"), d("1.50")], glecimal.compare)
    |> list.map(glecimal.to_string)
    == ["-1.5", "1.50", "2"]
}

pub fn rounding_table_test() {
  let row = fn(rounding) {
    ["2.5", "-2.5", "2.4", "-2.4"]
    |> list.map(fn(value) {
      let assert Ok(rounded) = glecimal.round(d(value), scale: 0, rounding:)
      glecimal.to_string(rounded)
    })
  }
  assert row(HalfEven) == ["2", "-2", "2", "-2"]
  assert row(HalfAwayFromZero) == ["3", "-3", "2", "-2"]
  assert row(HalfTowardZero) == ["2", "-2", "2", "-2"]
  assert row(TowardZero) == ["2", "-2", "2", "-2"]
  assert row(AwayFromZero) == ["3", "-3", "3", "-3"]
  assert row(Floor) == ["2", "-3", "2", "-3"]
  assert row(Ceiling) == ["3", "-2", "3", "-2"]
}

pub fn division_test() {
  assert glecimal.divide(d("10"), by: d("3"), scale: 2, rounding: HalfEven)
    |> result.map(glecimal.to_string)
    == Ok("3.33")
}

pub fn products_that_round_once_test() {
  let price = d("19.90")
  let assert Ok(rate) =
    glecimal.divide(d("1"), by: d("3"), scale: 64, rounding: HalfEven)
  assert glecimal.multiply_rounded(
      price,
      by: rate,
      scale: 2,
      rounding: HalfEven,
    )
    |> result.map(glecimal.to_string)
    == Ok("6.63")
}

pub fn powers_and_interest_test() {
  let monthly = d("1.0075")
  let assert Ok(factor) =
    glecimal.power(monthly, exponent: 12, scale: 10, rounding: HalfEven)
  assert glecimal.to_string(factor) == "1.0938068977"
  let assert Ok(future) = glecimal.multiply(d("1000.00"), factor)
  assert glecimal.round(future, scale: 2, rounding: HalfEven)
    |> result.map(glecimal.to_string)
    == Ok("1093.81")
  let assert Ok(discount) =
    glecimal.power(monthly, exponent: -12, scale: 10, rounding: HalfEven)
  assert glecimal.to_string(discount) == "0.9142381550"
  let assert Ok(present) = glecimal.multiply(d("1000.00"), discount)
  assert glecimal.round(present, scale: 2, rounding: HalfEven)
    |> result.map(glecimal.to_string)
    == Ok("914.24")
  assert glecimal.power(monthly, exponent: 960, scale: 2, rounding: HalfEven)
    |> result.is_ok
  assert glecimal.power(
      d("1.00416667"),
      exponent: 360,
      scale: 8,
      rounding: HalfEven,
    )
    |> result.is_ok
}

pub fn allocation_test() {
  assert glecimal.split(d("100.00"), into: 3) |> texts
    == Ok(["33.34", "33.33", "33.33"])
  assert glecimal.allocate(d("1000.00"), weights: [d("50"), d("30"), d("20")])
    |> texts
    == Ok(["500.00", "300.00", "200.00"])
}

pub fn invoice() -> Result(List(money.Money), money.MoneyError) {
  use price <- result.try(money.from_minor_units(19_990, in: currency.brl))
  use rate <- result.try(
    glecimal.parse("0.0725") |> result.map_error(money.InvalidAmount),
  )
  use tax <- result.try(money.multiply(price, by: rate, rounding: HalfEven))
  use total <- result.try(money.add(price, tax))
  money.split(total, into: 3)
}

pub fn money_test() {
  assert invoice() |> result.map(list.map(_, money.to_string))
    == Ok(["BRL 71.47", "BRL 71.46", "BRL 71.46"])
  assert currency.iso_4217_published == "2026-09-17"
  assert list.length(currency.listed()) == 165
  assert money.parse("BRL 214.39") |> result.map(money.to_string)
    == Ok("BRL 214.39")
}

pub fn display_and_forms_test() {
  let amount = d("1234567.89")
  assert notation.format(amount, notation.brazilian) == "1.234.567,89"
  assert notation.format(amount, notation.english) == "1,234,567.89"
  let read = fn(text) {
    notation.parse(text, notation.brazilian) |> result.map(glecimal.to_string)
  }
  assert read("1.234,56") == Ok("1234.56")
  assert read("1234,56") == Ok("1234.56")
  assert read("12.34,5") == Error(InvalidGrouping(2))
  assert read("0.500") == Error(InvalidGrouping(1))
  let assert Ok(swiss) =
    notation.new(decimal_separator: ".", group_separator: "'")
  assert notation.format(amount, swiss) == "1'234'567.89"
}

pub fn json_test() {
  let body = "{\"total\": \"214.39\"}"
  let assert Ok(total) =
    json.parse(body, decode.at(["total"], glecimal.decoder()))
  assert json.to_string(
      json.object([#("total", json.string(glecimal.to_string(total)))]),
    )
    == "{\"total\":\"214.39\"}"
  assert json.parse(
      "{\"amount\": \"214.39\", \"currency\": \"BRL\"}",
      money.decoder(),
    )
    |> result.map(money.to_string)
    == Ok("BRL 214.39")
}

pub fn limits_test() {
  assert glecimal.max_digits == 128
  assert glecimal.max_scale == 64
  assert glecimal.max_power_digits == 10_000
  assert glecimal.max_parts == 100_000
}
