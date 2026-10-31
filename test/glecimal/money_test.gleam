import gleam/json
import gleam/list
import gleam/order
import gleam/result
import glecimal.{type Decimal, HalfEven, WouldRound}
import glecimal/currency
import glecimal/money.{
  Arithmetic, CurrencyMismatch, InvalidAmount, MalformedText,
  UnknownCurrencyCode,
}

fn d(text: String) -> Decimal {
  let assert Ok(value) = glecimal.parse(text)
  value
}

fn texts(outcome: Result(List(money.Money), e)) -> Result(List(String), e) {
  result.map(outcome, list.map(_, money.to_string))
}

pub fn currencies_follow_iso_4217_test() {
  assert currency.from_code("BRL") == Ok(currency.brl)
  assert currency.minor_units(currency.jpy) == 0
  assert currency.minor_units(currency.bhd) == 3
  assert currency.minor_units(currency.clf) == 4
  assert currency.numeric_code(currency.brl) == 986
  assert currency.name(currency.brl) == "Brazilian Real"
  assert currency.from_code("brl") == Error(Nil)
  assert currency.from_code("XAU") == Error(Nil)
  assert list.length(currency.listed()) == 165
}

pub fn amounts_take_the_currency_scale_test() {
  assert money.new(d("10.5"), in: currency.brl) |> result.map(money.to_string)
    == Ok("BRL 10.50")
  assert money.new(d("10.505"), in: currency.brl)
    == Error(Arithmetic(WouldRound))
  assert money.new_rounded(d("10.505"), in: currency.brl, rounding: HalfEven)
    |> result.map(money.to_string)
    == Ok("BRL 10.50")
  assert money.from_minor_units(1050, in: currency.jpy)
    |> result.map(money.to_string)
    == Ok("JPY 1050")
  let assert Ok(price) = money.from_minor_units(1050, in: currency.brl)
  assert money.to_minor_units(price) == Ok(1050)
}

pub fn currencies_never_mix_test() {
  let assert Ok(real) = money.from_minor_units(100, in: currency.brl)
  let assert Ok(dollar) = money.from_minor_units(100, in: currency.usd)
  assert money.add(real, dollar)
    == Error(CurrencyMismatch(expected: currency.brl, found: currency.usd))
  assert money.compare(real, dollar) |> result.is_error
  assert money.compare(real, real) == Ok(order.Eq)
  assert money.sum([real, dollar], in: currency.brl)
    == Error(CurrencyMismatch(expected: currency.brl, found: currency.usd))
}

pub fn multiply_rounds_once_test() {
  let assert Ok(price) = money.from_minor_units(1999, in: currency.brl)
  assert money.multiply(price, by: d("0.0725"), rounding: HalfEven)
    |> result.map(money.to_string)
    == Ok("BRL 1.45")
  // A factor computed to 64 places still meets a single rounding.
  let assert Ok(third) =
    glecimal.divide(d("1"), by: d("3"), scale: 64, rounding: HalfEven)
  let assert Ok(ten) = money.from_minor_units(1000, in: currency.brl)
  assert money.multiply(ten, by: third, rounding: HalfEven)
    |> result.map(money.to_string)
    == Ok("BRL 3.33")
}

pub fn splits_add_up_test() {
  let assert Ok(bill) = money.from_minor_units(10_000, in: currency.brl)
  assert money.split(bill, into: 3) |> texts
    == Ok(["BRL 33.34", "BRL 33.33", "BRL 33.33"])
  assert money.allocate(bill, weights: [d("70"), d("30")]) |> texts
    == Ok(["BRL 70.00", "BRL 30.00"])
}

pub fn text_test() {
  assert money.parse("BRL 1234.5") |> result.map(money.to_string)
    == Ok("BRL 1234.50")
  assert money.parse("BRL1234.50") == Error(MalformedText)
  assert money.parse("XYZ 1.00") == Error(UnknownCurrencyCode("XYZ"))
  assert money.parse("BRL 1,00")
    == Error(InvalidAmount(glecimal.UnexpectedCharacter(5, ",")))
  assert money.parse("BRL 12x")
    == Error(InvalidAmount(glecimal.UnexpectedCharacter(6, "x")))
  assert money.parse("BRL 12.")
    == Error(InvalidAmount(glecimal.MissingDigits(7)))
  assert money.parse("JPY 10.5") == Error(Arithmetic(WouldRound))
}

pub fn decoder_names_the_reason_test() {
  let assert Error(json.UnableToDecode([error])) =
    json.parse(
      "{\"amount\": \"10.505\", \"currency\": \"BRL\"}",
      money.decoder(),
    )
  assert error.path == ["amount"]
  assert error.expected
    == "an amount in BRL (the conversion would drop nonzero digits)"
  let assert Error(json.UnableToDecode([error])) =
    json.parse("{\"amount\": \"1\", \"currency\": \"ZZZ\"}", money.decoder())
  assert error.path == ["currency"]
}

pub fn decoder_test() {
  assert json.parse(
      "{\"amount\": \"10.5\", \"currency\": \"BRL\"}",
      money.decoder(),
    )
    |> result.map(money.to_string)
    == Ok("BRL 10.50")
  assert json.parse(
      "{\"amount\": 10.5, \"currency\": \"BRL\"}",
      money.decoder(),
    )
    |> result.is_error
  assert json.parse(
      "{\"amount\": \"10.5\", \"currency\": \"ZZZ\"}",
      money.decoder(),
    )
    |> result.is_error
}

pub fn messages_test() {
  assert money.describe_error(CurrencyMismatch(currency.brl, currency.usd))
    == "expected BRL, found USD"
}
