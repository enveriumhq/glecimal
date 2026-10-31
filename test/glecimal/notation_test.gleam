import gleam/result
import gleam/string
import glecimal.{
  type Decimal, EmptyText, InvalidGrouping, MissingDigits, TextTooLong,
  TooManyDigits, UnexpectedCharacter,
}
import glecimal/notation.{InvalidSeparator, SameSeparators}

fn d(text: String) -> Decimal {
  let assert Ok(value) = glecimal.parse(text)
  value
}

fn read(
  text: String,
  style: notation.Notation,
) -> Result(String, glecimal.ParseError) {
  notation.parse(text, style) |> result.map(glecimal.to_string)
}

pub fn format_groups_the_integer_digits_test() {
  assert notation.format(d("1234567.89"), notation.brazilian) == "1.234.567,89"
  assert notation.format(d("-1234567.89"), notation.english) == "-1,234,567.89"
  assert notation.format(d("999"), notation.brazilian) == "999"
  assert notation.format(d("1000"), notation.brazilian) == "1.000"
  assert notation.format(d("0.50"), notation.brazilian) == "0,50"
  assert notation.format(d("1234567.89"), notation.plain) == "1234567.89"
}

pub fn parse_reads_grouped_and_ungrouped_input_test() {
  assert read("1.234,56", notation.brazilian) == Ok("1234.56")
  assert read("1234,56", notation.brazilian) == Ok("1234.56")
  assert read("-1.234.567", notation.brazilian) == Ok("-1234567")
  assert read("1,234.5", notation.english) == Ok("1234.5")
  assert read("1.234", notation.english) == Ok("1.234")
  assert read("1.234", notation.brazilian) == Ok("1234")
}

pub fn parse_refuses_a_leading_zero_group_test() {
  // English input in a Brazilian field must not read as a thousand times more.
  assert read("0.500", notation.brazilian) == Error(InvalidGrouping(1))
  assert read("-0.001", notation.brazilian) == Error(InvalidGrouping(2))
  assert read("0,250", notation.english) == Error(InvalidGrouping(1))
  assert read("01.234", notation.brazilian) == Error(InvalidGrouping(2))
  assert read("0,500", notation.brazilian) == Ok("0.500")
  assert read("0500", notation.brazilian) == Ok("500")
}

pub fn parse_refuses_misplaced_groups_test() {
  assert read("12.34,5", notation.brazilian) == Error(InvalidGrouping(2))
  assert read("1234.567", notation.brazilian) == Error(InvalidGrouping(4))
  assert read("1.2345", notation.brazilian) == Error(InvalidGrouping(1))
  assert read("1.234.", notation.brazilian) == Error(InvalidGrouping(5))
  assert read("1,234.5", notation.brazilian)
    == Error(UnexpectedCharacter(5, "."))
  assert read("1,", notation.brazilian) == Error(MissingDigits(2))
  assert read("", notation.brazilian) == Error(EmptyText)
  assert read("R$ 1,00", notation.brazilian)
    == Error(UnexpectedCharacter(0, "R"))
  assert read("1.234,56", notation.plain) == Error(UnexpectedCharacter(5, ","))
}

pub fn parse_keeps_the_bounds_test() {
  let grouped = "1" <> string.repeat(".000", 43)
  assert read(grouped, notation.brazilian) == Error(TooManyDigits(130))
  let widest = "9" <> string.repeat(".999", 21) <> "," <> string.repeat("9", 64)
  assert read(widest, notation.brazilian)
    == Ok(string.repeat("9", 64) <> "." <> string.repeat("9", 64))
  assert read(string.repeat("1", 300), notation.brazilian)
    == Error(TextTooLong(300))
}

pub fn custom_notations_test() {
  let assert Ok(swiss) =
    notation.new(decimal_separator: ".", group_separator: "'")
  assert notation.format(d("1234567.5"), swiss) == "1'234'567.5"
  assert read("1'234.5", swiss) == Ok("1234.5")
  let assert Ok(si) =
    notation.new(decimal_separator: ",", group_separator: "\u{202F}")
  assert notation.format(d("1234567.5"), si) == "1\u{202F}234\u{202F}567,5"
  assert read("1\u{202F}234,5", si) == Ok("1234.5")
  assert notation.new(decimal_separator: ",", group_separator: ",")
    == Error(SameSeparators)
  assert notation.new(decimal_separator: "", group_separator: ".")
    == Error(InvalidSeparator(""))
  assert notation.new(decimal_separator: "5", group_separator: ".")
    == Error(InvalidSeparator("5"))
  assert notation.new(decimal_separator: ".", group_separator: "--")
    == Error(InvalidSeparator("--"))
}

pub fn messages_test() {
  assert notation.describe_error(SameSeparators)
    == "the decimal and group separators are the same"
}
