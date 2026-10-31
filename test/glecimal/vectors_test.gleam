//// Replays test/vectors/glecimal.json, which scripts/vectors.py computes
//// with Python's decimal module, on whichever target runs the tests.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/order
import gleam/result
import gleam/string
import glecimal.{
  type ArithmeticError, type Decimal, type ParseError, type Rounding,
  AwayFromZero, Ceiling, DivisionByZero, EmptyText, Floor, HalfAwayFromZero,
  HalfEven, HalfTowardZero, IntegerOutOfRange, InvalidGrouping, MissingDigits,
  NegativeWeight, NoParts, Overflow, PowerTooLarge, ScaleOutOfRange, TextTooLong,
  TooManyDigits, TooManyFractionDigits, TooManyParts, TowardZero,
  UnexpectedCharacter, WouldRound, ZeroTotalWeight,
}
import simplifile

pub fn vectors_test() {
  let assert Ok(text) = simplifile.read("test/vectors/glecimal.json")
  let assert Ok(cases) =
    json.parse(text, decode.at(["cases"], decode.list(decode.dynamic)))
  let failures =
    list.filter_map(cases, fn(vector) {
      case check(vector) {
        Ok(Nil) -> Error(Nil)
        Error(message) -> Ok(message)
      }
    })
  assert list.length(cases) > 11_000
  assert list.take(failures, 10) == []
}

fn check(vector: Dynamic) -> Result(Nil, String) {
  use op <- result.try(field(vector, "op", decode.string))
  use actual <- result.try(run(op, vector))
  use expected <- result.try(expected(vector))
  case actual == expected {
    True -> Ok(Nil)
    False ->
      Error(
        string.inspect(vector)
        <> " gave "
        <> string.inspect(actual)
        <> ", expected "
        <> string.inspect(expected),
      )
  }
}

/// Runs one vector's operation; the outcome is the canonical text, or the
/// error's category as the vectors name it.
fn run(op: String, vector: Dynamic) -> Result(Result(String, String), String) {
  case op {
    "parse" -> {
      use text <- result.try(field(vector, "text", decode.string))
      Ok(
        glecimal.parse(text)
        |> result.map(glecimal.to_string)
        |> result.map_error(parse_category),
      )
    }
    "add" | "subtract" | "multiply" -> {
      use a <- result.try(operand(vector, "a"))
      use b <- result.try(operand(vector, "b"))
      let operation = case op {
        "add" -> glecimal.add
        "subtract" -> glecimal.subtract
        _ -> glecimal.multiply
      }
      Ok(arithmetic(operation(a, b)))
    }
    "compare" -> {
      use a <- result.try(operand(vector, "a"))
      use b <- result.try(operand(vector, "b"))
      Ok(Ok(int.to_string(order.to_int(glecimal.compare(a, b)))))
    }
    "multiply_rounded" -> {
      use a <- result.try(operand(vector, "a"))
      use b <- result.try(operand(vector, "b"))
      use scale <- result.try(field(vector, "scale", decode.int))
      use rounding <- result.try(rounding(vector))
      Ok(arithmetic(glecimal.multiply_rounded(a, by: b, scale:, rounding:)))
    }
    "divide" -> {
      use a <- result.try(operand(vector, "a"))
      use b <- result.try(operand(vector, "b"))
      use scale <- result.try(field(vector, "scale", decode.int))
      use rounding <- result.try(rounding(vector))
      Ok(arithmetic(glecimal.divide(a, by: b, scale:, rounding:)))
    }
    "round" -> {
      use a <- result.try(operand(vector, "a"))
      use scale <- result.try(field(vector, "scale", decode.int))
      use rounding <- result.try(rounding(vector))
      Ok(arithmetic(glecimal.round(a, scale:, rounding:)))
    }
    "rescale" -> {
      use a <- result.try(operand(vector, "a"))
      use scale <- result.try(field(vector, "scale", decode.int))
      Ok(arithmetic(glecimal.rescale(a, scale:)))
    }
    "power" -> {
      use a <- result.try(operand(vector, "a"))
      use exponent <- result.try(field(vector, "exponent", decode.int))
      use scale <- result.try(field(vector, "scale", decode.int))
      use rounding <- result.try(rounding(vector))
      Ok(arithmetic(glecimal.power(a, exponent:, scale:, rounding:)))
    }
    "allocate" -> {
      use a <- result.try(operand(vector, "a"))
      use texts <- result.try(field(
        vector,
        "weights",
        decode.list(decode.string),
      ))
      use weights <- result.try(list.try_map(texts, parse_operand))
      Ok(
        glecimal.allocate(a, weights:)
        |> result.map(fn(parts) {
          parts |> list.map(glecimal.to_string) |> string.join(",")
        })
        |> result.map_error(arithmetic_category),
      )
    }
    _ -> Error("unknown op " <> op)
  }
}

fn expected(vector: Dynamic) -> Result(Result(String, String), String) {
  let ok =
    decode.one_of(decode.string, [
      decode.int |> decode.map(int.to_string),
      decode.list(decode.string) |> decode.map(string.join(_, ",")),
    ])
  case field(vector, "ok", ok), field(vector, "error", decode.string) {
    Ok(value), _ -> Ok(Ok(value))
    Error(_), Ok("negative_weight") -> {
      use index <- result.try(field(vector, "index", decode.int))
      Ok(Error("negative_weight:" <> int.to_string(index)))
    }
    Error(_), Ok(error) -> Ok(Error(error))
    Error(message), Error(_) -> Error(message)
  }
}

fn field(
  vector: Dynamic,
  name: String,
  decoder: decode.Decoder(a),
) -> Result(a, String) {
  decode.run(vector, decode.at([name], decoder))
  |> result.map_error(fn(_) {
    "no field " <> name <> " in " <> string.inspect(vector)
  })
}

fn operand(vector: Dynamic, name: String) -> Result(Decimal, String) {
  use text <- result.try(field(vector, name, decode.string))
  parse_operand(text)
}

fn parse_operand(text: String) -> Result(Decimal, String) {
  glecimal.parse(text)
  |> result.map_error(fn(_) { "unparsable operand " <> text })
}

fn rounding(vector: Dynamic) -> Result(Rounding, String) {
  use name <- result.try(field(vector, "rounding", decode.string))
  case name {
    "half_even" -> Ok(HalfEven)
    "half_away_from_zero" -> Ok(HalfAwayFromZero)
    "half_toward_zero" -> Ok(HalfTowardZero)
    "toward_zero" -> Ok(TowardZero)
    "away_from_zero" -> Ok(AwayFromZero)
    "floor" -> Ok(Floor)
    "ceiling" -> Ok(Ceiling)
    _ -> Error("unknown rounding " <> name)
  }
}

fn arithmetic(
  outcome: Result(Decimal, ArithmeticError),
) -> Result(String, String) {
  outcome
  |> result.map(glecimal.to_string)
  |> result.map_error(arithmetic_category)
}

fn parse_category(error: ParseError) -> String {
  case error {
    EmptyText
    | UnexpectedCharacter(..)
    | MissingDigits(..)
    | InvalidGrouping(..) -> "syntax"
    TextTooLong(..) | TooManyDigits(..) | TooManyFractionDigits(..) ->
      "too_long"
  }
}

fn arithmetic_category(error: ArithmeticError) -> String {
  case error {
    Overflow -> "overflow"
    DivisionByZero -> "division_by_zero"
    ScaleOutOfRange(..) -> "scale"
    WouldRound -> "would_round"
    IntegerOutOfRange -> "integer_out_of_range"
    PowerTooLarge -> "power_too_large"
    NoParts -> "no_parts"
    TooManyParts(..) -> "too_many_parts"
    NegativeWeight(index) -> "negative_weight:" <> int.to_string(index)
    ZeroTotalWeight -> "zero_total_weight"
  }
}
