import gleam/list
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
  assert notation.format(d("1234567.89"), notation.pt_br) == "1.234.567,89"
  assert notation.format(d("-1234567.89"), notation.en_us) == "-1,234,567.89"
  assert notation.format(d("999"), notation.pt_br) == "999"
  assert notation.format(d("1000"), notation.pt_br) == "1.000"
  assert notation.format(d("0.50"), notation.pt_br) == "0,50"
  assert notation.format(d("1234567.89"), notation.plain) == "1234567.89"
}

pub fn parse_reads_grouped_and_ungrouped_input_test() {
  assert read("1.234,56", notation.pt_br) == Ok("1234.56")
  assert read("1234,56", notation.pt_br) == Ok("1234.56")
  assert read("-1.234.567", notation.pt_br) == Ok("-1234567")
  assert read("1,234.5", notation.en_us) == Ok("1234.5")
  assert read("1.234", notation.en_us) == Ok("1.234")
  assert read("1.234", notation.pt_br) == Ok("1234")
}

pub fn parse_refuses_a_leading_zero_group_test() {
  // English input in a Brazilian field must not read as a thousand times more.
  assert read("0.500", notation.pt_br) == Error(InvalidGrouping(1))
  assert read("-0.001", notation.pt_br) == Error(InvalidGrouping(2))
  assert read("0,250", notation.en_us) == Error(InvalidGrouping(1))
  assert read("01.234", notation.pt_br) == Error(InvalidGrouping(2))
  assert read("0,500", notation.pt_br) == Ok("0.500")
  assert read("0500", notation.pt_br) == Ok("500")
}

pub fn parse_refuses_misplaced_groups_test() {
  assert read("12.34,5", notation.pt_br) == Error(InvalidGrouping(2))
  assert read("1234.567", notation.pt_br) == Error(InvalidGrouping(4))
  assert read("1.2345", notation.pt_br) == Error(InvalidGrouping(1))
  assert read("1.234.", notation.pt_br) == Error(InvalidGrouping(5))
  assert read("1,234.5", notation.pt_br) == Error(UnexpectedCharacter(5, "."))
  assert read("1,", notation.pt_br) == Error(MissingDigits(2))
  assert read("", notation.pt_br) == Error(EmptyText)
  assert read("R$ 1,00", notation.pt_br) == Error(UnexpectedCharacter(0, "R"))
  assert read("1.234,56", notation.plain) == Error(UnexpectedCharacter(5, ","))
}

pub fn parse_keeps_the_bounds_test() {
  let grouped = "1" <> string.repeat(".000", 43)
  assert read(grouped, notation.pt_br) == Error(TooManyDigits(130))
  let widest = "9" <> string.repeat(".999", 21) <> "," <> string.repeat("9", 64)
  assert read(widest, notation.pt_br)
    == Ok(string.repeat("9", 64) <> "." <> string.repeat("9", 64))
  assert read(string.repeat("1", 300), notation.pt_br)
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

pub fn locales_follow_cldr_test() {
  assert notation.for_locale("pt-BR") == Ok(notation.pt_br)
  assert notation.for_locale("pt_br") == Ok(notation.pt_br)
  assert notation.for_locale("PT-br") == Ok(notation.pt_br)
  assert notation.for_locale("en-US") == Ok(notation.en_us)
  assert notation.for_locale("en-GB") == Ok(notation.en_gb)
  assert notation.for_locale("de-DE") == Ok(notation.de_de)
  assert notation.for_locale("fr-FR") == Ok(notation.fr_fr)
  assert notation.for_locale("de-CH") == Ok(notation.de_ch)
  // Formats the notation model cannot reproduce are not in the table.
  assert notation.for_locale("es-ES") == Error(Nil)
  assert notation.for_locale("pt-PT") == Error(Nil)
  assert notation.for_locale("en-IN") == Error(Nil)
  assert notation.for_locale("sv-SE") == Error(Nil)
  assert notation.for_locale("xx-YY") == Error(Nil)
  assert notation.cldr_version == "48.0"
  assert list.length(notation.locales()) == 81
  assert list.contains(notation.locales(), "pt-BR")
}

pub fn locale_formats_test() {
  let amount = d("1234567.89")
  assert notation.format(amount, notation.fr_fr) == "1\u{202F}234\u{202F}567,89"
  assert notation.format(amount, notation.de_ch) == "1'234'567.89"
  assert notation.format(amount, notation.de_de) == "1.234.567,89"
}

pub fn typed_spaces_and_apostrophes_count_as_separators_test() {
  assert read("1 234,5", notation.fr_fr) == Ok("1234.5")
  assert read("1\u{00A0}234,5", notation.fr_fr) == Ok("1234.5")
  assert read("1\u{202F}234,5", notation.fr_fr) == Ok("1234.5")
  assert read("1'234.5", notation.de_ch) == Ok("1234.5")
  assert read("1\u{2019}234.5", notation.de_ch) == Ok("1234.5")
  // Only where the notation groups with that kind of character.
  assert read("1 234,5", notation.pt_br) == Error(UnexpectedCharacter(1, " "))
}
