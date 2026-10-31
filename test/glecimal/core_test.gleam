import gleam/json
import gleam/list
import gleam/order
import gleam/result
import gleam/string
import glecimal.{
  type Decimal, DivisionByZero, EmptyText, HalfEven, IntegerOutOfRange,
  MissingDigits, NegativeWeight, NoParts, Overflow, PowerTooLarge,
  ScaleOutOfRange, TextTooLong, TooManyDigits, TooManyFractionDigits,
  TooManyParts, TowardZero, UnexpectedCharacter, WouldRound, ZeroTotalWeight,
}

fn d(text: String) -> Decimal {
  let assert Ok(value) = glecimal.parse(text)
  value
}

fn text(outcome: Result(Decimal, e)) -> Result(String, e) {
  result.map(outcome, glecimal.to_string)
}

pub fn parse_reports_where_and_why_test() {
  assert glecimal.parse("") == Error(EmptyText)
  assert glecimal.parse("-") == Error(MissingDigits(1))
  assert glecimal.parse("1.") == Error(MissingDigits(2))
  assert glecimal.parse(".5") == Error(UnexpectedCharacter(0, "."))
  assert glecimal.parse("1e3") == Error(UnexpectedCharacter(1, "e"))
  assert glecimal.parse("+1") == Error(UnexpectedCharacter(0, "+"))
  assert glecimal.parse("--1") == Error(UnexpectedCharacter(1, "-"))
  assert glecimal.parse("1.2.3") == Error(UnexpectedCharacter(3, "."))
  assert glecimal.parse("12 ") == Error(UnexpectedCharacter(2, " "))
  assert glecimal.parse("١") == Error(UnexpectedCharacter(0, "١"))
  assert glecimal.parse("1\u{0301}")
    == Error(UnexpectedCharacter(1, "\u{0301}"))
  assert glecimal.parse(string.repeat("9", 129)) == Error(TooManyDigits(129))
  assert glecimal.parse("0." <> string.repeat("1", 65))
    == Error(TooManyFractionDigits(65))
  assert glecimal.parse(string.repeat("1", 10_000))
    == Error(TextTooLong(10_000))
}

pub fn parse_reads_every_value_a_decimal_holds_test() {
  let widest = string.repeat("9", 64) <> "." <> string.repeat("9", 64)
  assert glecimal.parse("-" <> widest) |> text == Ok("-" <> widest)
  assert glecimal.parse(string.repeat("9", 128)) |> text
    == Ok(string.repeat("9", 128))
  assert glecimal.parse(string.repeat("0", 60) <> "1.5") |> text == Ok("1.5")
  // What `to_string` writes, `parse` reads back.
  let assert Ok(third) =
    glecimal.divide(d("1"), by: d("3"), scale: 64, rounding: HalfEven)
  assert glecimal.parse(glecimal.to_string(third)) == Ok(third)
}

pub fn parse_keeps_the_written_scale_test() {
  assert glecimal.to_string(d("1.50")) == "1.50"
  assert glecimal.scale(d("1.50")) == 2
  assert glecimal.to_string(d("-007.500")) == "-7.500"
  assert glecimal.to_string(d("-0.00")) == "0.00"
  assert glecimal.to_string(glecimal.zero()) == "0"
}

pub fn equality_is_canonical_and_compare_is_numeric_test() {
  assert d("1.5") != d("1.50")
  assert glecimal.compare(d("1.5"), d("1.50")) == order.Eq
  assert d("-0") == d("0")
  assert d("-0.0") == d("0.0")
  assert glecimal.compare(d("-2"), d("1")) == order.Lt
  assert glecimal.compare(d("-2"), d("-10")) == order.Gt
  assert glecimal.scale(glecimal.min(d("1.5"), d("1.50"))) == 1
  assert glecimal.scale(glecimal.max(d("1.50"), d("1.5"))) == 2
}

pub fn integers_are_exact_on_every_target_test() {
  assert text(glecimal.from_int(-42)) == Ok("-42")
  assert text(glecimal.from_int(glecimal.max_safe_integer))
    == Ok("9007199254740991")
  assert glecimal.from_int(glecimal.max_safe_integer + 1)
    == Error(IntegerOutOfRange)
  assert glecimal.from_int(-glecimal.max_safe_integer - 1)
    == Error(IntegerOutOfRange)
}

pub fn minor_units_test() {
  assert text(glecimal.from_minor_units(1990, scale: 2)) == Ok("19.90")
  assert text(glecimal.from_minor_units(-5, scale: 2)) == Ok("-0.05")
  assert glecimal.from_minor_units(1, scale: 65) == Error(ScaleOutOfRange(65))
  assert glecimal.to_minor_units(d("19.9"), scale: 2) == Ok(1990)
  assert glecimal.to_minor_units(d("-19.90"), scale: 2) == Ok(-1990)
  assert glecimal.to_minor_units(d("19.905"), scale: 2) == Error(WouldRound)
  assert glecimal.to_minor_units(d("9007199254740992"), scale: 0)
    == Error(IntegerOutOfRange)
  assert glecimal.to_minor_units(d(string.repeat("9", 127)), scale: 2)
    == Error(IntegerOutOfRange)
}

pub fn overflow_at_the_bound_test() {
  let nines = d(string.repeat("9", 64))
  let assert Ok(above) = glecimal.add(nines, d("2"))
  // (10^64 − 1)(10^64 + 1) = 10^128 − 1, the largest magnitude.
  let assert Ok(largest) = glecimal.multiply(nines, above)
  assert glecimal.to_string(largest) == string.repeat("9", 128)
  assert glecimal.add(largest, d("1")) == Error(Overflow)
  assert glecimal.subtract(glecimal.negate(largest), d("1")) == Error(Overflow)
  assert text(glecimal.add(largest, d("-1")))
    == Ok(string.repeat("9", 127) <> "8")
  let tiny = d("0." <> string.repeat("0", 31) <> "1")
  let assert Ok(scale_64) = glecimal.multiply(tiny, tiny)
  assert glecimal.scale(scale_64) == 64
  assert glecimal.multiply(scale_64, tiny) == Error(Overflow)
}

pub fn scale_operations_test() {
  assert text(glecimal.round(d("2.345"), scale: 2, rounding: HalfEven))
    == Ok("2.34")
  assert text(glecimal.round(d("7"), scale: 2, rounding: TowardZero))
    == Ok("7.00")
  assert glecimal.round(d("1"), scale: -1, rounding: HalfEven)
    == Error(ScaleOutOfRange(-1))
  assert text(glecimal.rescale(d("2.500"), scale: 1)) == Ok("2.5")
  assert glecimal.rescale(d("2.55"), scale: 1) == Error(WouldRound)
  assert glecimal.to_string(glecimal.normalize(d("-1.100"))) == "-1.1"
  assert glecimal.to_string(glecimal.normalize(d("0.000"))) == "0"
  assert glecimal.to_string(glecimal.normalize(d("100"))) == "100"
}

pub fn division_test() {
  assert glecimal.divide(d("1"), by: d("0.00"), scale: 2, rounding: HalfEven)
    == Error(DivisionByZero)
  assert text(glecimal.divide(d("2"), by: d("3"), scale: 6, rounding: HalfEven))
    == Ok("0.666667")
}

pub fn power_test() {
  assert text(glecimal.power(d("0"), exponent: 0, scale: 2, rounding: HalfEven))
    == Ok("1.00")
  assert glecimal.power(d("0.0"), exponent: -1, scale: 2, rounding: HalfEven)
    == Error(DivisionByZero)
  assert text(glecimal.power(
      d("1.01"),
      exponent: -12,
      scale: 8,
      rounding: HalfEven,
    ))
    == Ok("0.88744923")
  assert glecimal.power(d("9"), exponent: 10_001, scale: 0, rounding: HalfEven)
    == Error(PowerTooLarge)
  // A zero base costs nothing per period, but the exponent is still bounded.
  assert glecimal.power(d("0"), exponent: 10_001, scale: 0, rounding: HalfEven)
    == Error(PowerTooLarge)
}

pub fn sum_sign_and_negation_test() {
  assert text(glecimal.sum([])) == Ok("0")
  assert text(glecimal.sum([d("0.1"), d("0.2"), d("-0.30")])) == Ok("0.00")
  assert glecimal.to_string(glecimal.negate(d("0.00"))) == "0.00"
  assert glecimal.to_string(glecimal.absolute_value(d("-3.5"))) == "3.5"
  assert glecimal.is_zero(d("0.000"))
  assert glecimal.is_negative(d("-0.01"))
  assert !glecimal.is_negative(d("-0.00"))
  assert glecimal.is_positive(d("0.01"))
  assert !glecimal.is_positive(d("0"))
}

pub fn allocation_test() {
  assert glecimal.allocate(d("100.00"), weights: [d("1"), d("1"), d("1")])
    |> result.map(list.map(_, glecimal.to_string))
    == Ok(["33.34", "33.33", "33.33"])
  assert glecimal.split(d("-0.05"), into: 3)
    |> result.map(list.map(_, glecimal.to_string))
    == Ok(["-0.02", "-0.02", "-0.01"])
  assert glecimal.allocate(d("1"), weights: []) == Error(NoParts)
  assert glecimal.allocate(d("1"), weights: [d("1"), d("-2")])
    == Error(NegativeWeight(1))
  assert glecimal.allocate(d("1"), weights: [d("0"), d("0.0")])
    == Error(ZeroTotalWeight)
  assert glecimal.split(d("1"), into: 0) == Error(NoParts)
  assert glecimal.split(d("1"), into: glecimal.max_parts + 1)
    == Error(TooManyParts(glecimal.max_parts + 1))
  assert glecimal.allocate(d("1"), weights: list.repeat(d("1"), 100_001))
    == Error(TooManyParts(100_001))
  assert glecimal.split(d("1.00"), into: glecimal.max_parts) |> result.is_ok
}

pub fn multiply_rounded_rounds_once_test() {
  let assert Ok(third) =
    glecimal.divide(d("1"), by: d("3"), scale: 64, rounding: HalfEven)
  assert glecimal.multiply(d("10.00"), third) == Error(Overflow)
  assert glecimal.multiply_rounded(
      d("10.00"),
      by: third,
      scale: 2,
      rounding: HalfEven,
    )
    |> text
    == Ok("3.33")
}

pub fn decoder_reads_strings_only_test() {
  assert json.parse("\"19.90\"", glecimal.decoder()) |> text == Ok("19.90")
  assert json.parse("19.90", glecimal.decoder()) |> result.is_error
  let assert Error(json.UnableToDecode([error])) =
    json.parse("\"19,90\"", glecimal.decoder())
  assert error.expected == "a decimal (unexpected \",\" at position 2)"
}

pub fn messages_test() {
  assert glecimal.describe_parse_error(UnexpectedCharacter(1, "e"))
    == "unexpected \"e\" at position 1"
  assert glecimal.describe_arithmetic_error(ScaleOutOfRange(70))
    == "scale 70 is outside 0 to 64"
  assert glecimal.describe_arithmetic_error(NegativeWeight(2))
    == "the weight at index 2 is negative"
}
