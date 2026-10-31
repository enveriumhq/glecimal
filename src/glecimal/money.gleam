//// An amount of money: a decimal held at exactly its currency's minor
//// units, so `BRL 10.50` always has two decimals and `JPY 1050` none.
////
//// Money never mixes currencies (adding `BRL` to `USD` is
//// `CurrencyMismatch`), its own arithmetic is exact, and a value with
//// nonzero digits beyond the currency's minor units comes in only through
//// `new_rounded` or `multiply`, each with a named rounding. Allocation works in minor
//// units, so the parts always add up to the whole.
////
//// ```gleam
//// import glecimal.{HalfEven}
//// import glecimal/currency
//// import glecimal/money
////
//// pub fn invoice() -> Result(List(money.Money), money.MoneyError) {
////   use price <- result.try(money.from_minor_units(19_990, in: currency.brl))
////   use rate <- result.try(
////     glecimal.parse("0.0725") |> result.map_error(money.InvalidAmount),
////   )
////   use tax <- result.try(money.multiply(price, by: rate, rounding: HalfEven))
////   use total <- result.try(money.add(price, tax))
////   money.split(total, into: 3)
//// }
//// ```

import gleam/dynamic/decode
import gleam/list
import gleam/order.{type Order}
import gleam/result
import gleam/string
import glecimal.{
  type ArithmeticError, type Decimal, type ParseError, type Rounding, EmptyText,
  InvalidGrouping, MissingDigits, TextTooLong, TooManyDigits,
  TooManyFractionDigits, UnexpectedCharacter,
}
import glecimal/currency.{type Currency}

/// An amount at its currency's scale.
pub opaque type Money {
  Money(amount: Decimal, currency: Currency)
}

/// Why a money operation has no result.
pub type MoneyError {
  /// The operation combined two currencies.
  CurrencyMismatch(expected: Currency, found: Currency)
  /// The arithmetic or allocation failed, for example `WouldRound` when an
  /// amount has nonzero digits beyond its currency's minor units.
  Arithmetic(ArithmeticError)
  /// `parse` read an amount it could not accept; positions count from the
  /// start of the whole text.
  InvalidAmount(ParseError)
  /// `parse` or `decoder` read a code that is not in ISO 4217.
  UnknownCurrencyCode(code: String)
  /// `parse` read a text that is not a code, one space and an amount.
  MalformedText
}

// ── Construction ───────────────────────────────────────────────────────────

/// `amount` in `currency`, exactly. Zeros are added up to the currency's
/// minor units; a nonzero digit beyond them is `Arithmetic(WouldRound)`.
pub fn new(
  amount: Decimal,
  in currency: Currency,
) -> Result(Money, MoneyError) {
  glecimal.rescale(amount, scale: currency.minor_units(currency))
  |> result.map(Money(_, currency))
  |> result.map_error(Arithmetic)
}

/// `amount` in `currency`, rounded to the currency's minor units.
pub fn new_rounded(
  amount: Decimal,
  in currency: Currency,
  rounding rounding: Rounding,
) -> Result(Money, MoneyError) {
  glecimal.round(amount, scale: currency.minor_units(currency), rounding:)
  |> result.map(Money(_, currency))
  |> result.map_error(Arithmetic)
}

/// An amount counted in minor units: `from_minor_units(1050, in:
/// currency.brl)` is `BRL 10.50`.
pub fn from_minor_units(
  units: Int,
  in currency: Currency,
) -> Result(Money, MoneyError) {
  glecimal.from_minor_units(units, scale: currency.minor_units(currency))
  |> result.map(Money(_, currency))
  |> result.map_error(Arithmetic)
}

/// The amount counted in minor units: `BRL 10.50` is `1050`.
pub fn to_minor_units(money: Money) -> Result(Int, MoneyError) {
  glecimal.to_minor_units(
    money.amount,
    scale: currency.minor_units(money.currency),
  )
  |> result.map_error(Arithmetic)
}

/// The amount, at the currency's scale.
pub fn amount(money: Money) -> Decimal {
  money.amount
}

pub fn currency(money: Money) -> Currency {
  money.currency
}

// ── Arithmetic ─────────────────────────────────────────────────────────────

pub fn add(a: Money, b: Money) -> Result(Money, MoneyError) {
  combine(a, b, glecimal.add)
}

pub fn subtract(a: Money, b: Money) -> Result(Money, MoneyError) {
  combine(a, b, glecimal.subtract)
}

fn combine(
  a: Money,
  b: Money,
  operation: fn(Decimal, Decimal) -> Result(Decimal, ArithmeticError),
) -> Result(Money, MoneyError) {
  use Nil <- result.try(same_currency(a.currency, b.currency))
  operation(a.amount, b.amount)
  |> result.map(Money(_, a.currency))
  |> result.map_error(Arithmetic)
}

/// The total of amounts in `currency`; `sum([], in: currency)` is zero.
pub fn sum(
  amounts: List(Money),
  in currency: Currency,
) -> Result(Money, MoneyError) {
  use zero <- result.try(new(glecimal.zero(), in: currency))
  list.try_fold(amounts, zero, add)
}

/// `money × factor` (a quantity, a rate, an exchange rate into the same
/// currency), rounded once to the currency's minor units, whatever the
/// factor's scale.
pub fn multiply(
  money: Money,
  by factor: Decimal,
  rounding rounding: Rounding,
) -> Result(Money, MoneyError) {
  glecimal.multiply_rounded(
    money.amount,
    by: factor,
    scale: currency.minor_units(money.currency),
    rounding:,
  )
  |> result.map(Money(_, money.currency))
  |> result.map_error(Arithmetic)
}

/// Splits the amount in proportion to `weights`, in minor units, so the
/// parts add up to it exactly; see `glecimal.allocate`.
pub fn allocate(
  money: Money,
  weights weights: List(Decimal),
) -> Result(List(Money), MoneyError) {
  glecimal.allocate(money.amount, weights:)
  |> result.map(list.map(_, Money(_, money.currency)))
  |> result.map_error(Arithmetic)
}

/// Splits the amount into `parts` equal shares, in minor units.
pub fn split(money: Money, into parts: Int) -> Result(List(Money), MoneyError) {
  glecimal.split(money.amount, into: parts)
  |> result.map(list.map(_, Money(_, money.currency)))
  |> result.map_error(Arithmetic)
}

pub fn negate(money: Money) -> Money {
  Money(..money, amount: glecimal.negate(money.amount))
}

pub fn absolute_value(money: Money) -> Money {
  Money(..money, amount: glecimal.absolute_value(money.amount))
}

// ── Comparison ─────────────────────────────────────────────────────────────

/// Compares two amounts in the same currency.
pub fn compare(a: Money, b: Money) -> Result(Order, MoneyError) {
  use Nil <- result.try(same_currency(a.currency, b.currency))
  Ok(glecimal.compare(a.amount, b.amount))
}

pub fn is_zero(money: Money) -> Bool {
  glecimal.is_zero(money.amount)
}

pub fn is_negative(money: Money) -> Bool {
  glecimal.is_negative(money.amount)
}

pub fn is_positive(money: Money) -> Bool {
  glecimal.is_positive(money.amount)
}

// ── Text and JSON ──────────────────────────────────────────────────────────

/// The canonical form for logs and audit trails: the code, one space and
/// the amount, as in `BRL 1234.50`. For display, format `amount` with
/// `glecimal/notation`.
pub fn to_string(money: Money) -> String {
  currency.code(money.currency) <> " " <> glecimal.to_string(money.amount)
}

/// Reads the form `to_string` writes. Zeros are added up to the currency's
/// minor units, so `BRL 5` is `BRL 5.00`; a nonzero digit beyond them is
/// `Arithmetic(WouldRound)`.
pub fn parse(text: String) -> Result(Money, MoneyError) {
  use #(code, amount_text) <- result.try(
    string.split_once(text, " ")
    |> result.replace_error(MalformedText),
  )
  use currency <- result.try(
    currency.from_code(code)
    |> result.replace_error(UnknownCurrencyCode(code)),
  )
  // The code is three ASCII letters, so the amount starts at position 4.
  let offset = string.byte_size(code) + 1
  use amount <- result.try(
    glecimal.parse(amount_text)
    |> result.map_error(fn(error) { InvalidAmount(shift(error, offset)) }),
  )
  new(amount, in: currency)
}

fn shift(error: ParseError, offset: Int) -> ParseError {
  case error {
    UnexpectedCharacter(position, character) ->
      UnexpectedCharacter(position + offset, character)
    MissingDigits(position) -> MissingDigits(position + offset)
    InvalidGrouping(position) -> InvalidGrouping(position + offset)
    EmptyText
    | TextTooLong(..)
    | TooManyDigits(..)
    | TooManyFractionDigits(..) -> error
  }
}

/// Reads `{"amount": "1234.50", "currency": "BRL"}`: the amount as a string
/// (numbers are refused) and the code in ISO 4217. A refusal names its
/// reason, at the path of the field that caused it.
pub fn decoder() -> decode.Decoder(Money) {
  use currency <- decode.field("currency", currency_decoder())
  use money <- decode.field("amount", amount_decoder(currency))
  decode.success(money)
}

fn currency_decoder() -> decode.Decoder(Currency) {
  use code <- decode.then(decode.string)
  case currency.from_code(code) {
    Ok(currency) -> decode.success(currency)
    Error(Nil) ->
      decode.failure(
        currency.usd,
        "an ISO 4217 code (\"" <> code <> "\" is not one)",
      )
  }
}

fn amount_decoder(currency: Currency) -> decode.Decoder(Money) {
  use amount <- decode.then(glecimal.decoder())
  case new(amount, in: currency) {
    Ok(money) -> decode.success(money)
    Error(error) ->
      decode.failure(
        Money(amount, currency),
        "an amount in "
          <> currency.code(currency)
          <> " ("
          <> describe_error(error)
          <> ")",
      )
  }
}

/// A sentence for logs and messages.
pub fn describe_error(error: MoneyError) -> String {
  case error {
    CurrencyMismatch(expected, found) ->
      "expected "
      <> currency.code(expected)
      <> ", found "
      <> currency.code(found)
    Arithmetic(error) -> glecimal.describe_arithmetic_error(error)
    InvalidAmount(error) -> glecimal.describe_parse_error(error)
    UnknownCurrencyCode(code) -> "\"" <> code <> "\" is not an ISO 4217 code"
    MalformedText -> "expected a currency code, one space and an amount"
  }
}

fn same_currency(
  expected: Currency,
  found: Currency,
) -> Result(Nil, MoneyError) {
  case expected == found {
    True -> Ok(Nil)
    False -> Error(CurrencyMismatch(expected:, found:))
  }
}
