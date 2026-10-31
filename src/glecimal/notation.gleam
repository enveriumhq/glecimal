//// Decimals as people write them: `1.234,56` in Brazil, `1,234.56` in
//// English. `format` writes a value for display and `parse` reads a form
//// field back, strictly: digit groups have exactly three digits or are not
//// used at all, a grouped number never starts with a zero group, and the
//// bounds of `glecimal.parse` apply. So `0.500` typed into a Brazilian field
//// is refused rather than read as five hundred.
////
//// ```gleam
//// import glecimal/notation
////
//// notation.format(amount, notation.brazilian)
//// // -> "1.234.567,89"
//// notation.parse("1.234,5", notation.brazilian)
//// // -> Ok(1234.5)
//// ```
////
//// A notation carries separators only. Currency symbols, spacing and
//// padding to a fixed scale are the caller's: `glecimal.rescale` a value to
//// two places before formatting it as an amount.

import gleam/bool
import gleam/list
import gleam/result
import gleam/string
import glecimal.{
  type Decimal, type ParseError, EmptyText, InvalidGrouping, MissingDigits,
  TextTooLong, TooManyDigits, TooManyFractionDigits, UnexpectedCharacter,
}

/// The separators a text uses: a decimal separator, and a group separator
/// between thousands, or none.
pub opaque type Notation {
  Notation(decimal_separator: String, group_separator: String)
}

/// Why `new` refused a pair of separators.
pub type NotationError {
  /// A separator must be one character that is not a digit or `-`; the
  /// group separator may also be empty, for no grouping.
  InvalidSeparator(separator: String)
  /// The two separators are the same character.
  SameSeparators
}

/// `1.234.567,89`: Brazil, and most of continental Europe.
pub const brazilian = Notation(decimal_separator: ",", group_separator: ".")

/// `1,234,567.89`: English-speaking countries.
pub const english = Notation(decimal_separator: ".", group_separator: ",")

/// `1234567.89`: the canonical text, ungrouped.
pub const plain = Notation(decimal_separator: ".", group_separator: "")

/// The longest text `parse` scans: 96 digits with every separator a
/// four-byte character, and a sign.
const max_text_bytes = 256

/// A notation with other separators, such as `'` for Swiss grouping or a
/// narrow no-break space (U+202F) for SI grouping.
pub fn new(
  decimal_separator decimal_separator: String,
  group_separator group_separator: String,
) -> Result(Notation, NotationError) {
  use Nil <- result.try(check_separator(decimal_separator))
  use Nil <- result.try(case group_separator {
    "" -> Ok(Nil)
    _ -> check_separator(group_separator)
  })
  case decimal_separator == group_separator {
    True -> Error(SameSeparators)
    False -> Ok(Notation(decimal_separator:, group_separator:))
  }
}

fn check_separator(separator: String) -> Result(Nil, NotationError) {
  case string.to_graphemes(separator) {
    [single] ->
      case is_digit(single) || single == "-" {
        True -> Error(InvalidSeparator(separator))
        False -> Ok(Nil)
      }
    _ -> Error(InvalidSeparator(separator))
  }
}

/// A sentence for logs and messages.
pub fn describe_error(error: NotationError) -> String {
  case error {
    InvalidSeparator(separator) ->
      "\""
      <> separator
      <> "\" is not a separator: use one character that is not a digit or -"
    SameSeparators -> "the decimal and group separators are the same"
  }
}

pub fn decimal_separator(notation: Notation) -> String {
  notation.decimal_separator
}

pub fn group_separator(notation: Notation) -> String {
  notation.group_separator
}

/// The value at its own scale, with the notation's separators.
pub fn format(decimal: Decimal, notation: Notation) -> String {
  let text = glecimal.to_string(decimal)
  let #(sign, body) = case text {
    "-" <> rest -> #("-", rest)
    _ -> #("", text)
  }
  case string.split_once(body, ".") {
    Ok(#(whole, fraction)) ->
      sign
      <> group(whole, notation.group_separator)
      <> notation.decimal_separator
      <> fraction
    Error(Nil) -> sign <> group(body, notation.group_separator)
  }
}

fn group(digits: String, separator: String) -> String {
  case separator {
    "" -> digits
    _ ->
      digits
      |> string.to_graphemes
      |> list.reverse
      |> list.sized_chunk(3)
      |> list.map(fn(chunk) { chunk |> list.reverse |> string.concat })
      |> list.reverse
      |> string.join(separator)
  }
}

/// Reads `-?digits(decimal-separator digits)?`, where the integer digits are
/// either ungrouped or grouped in threes. The scale is kept as written, so
/// `"1.234,50"` is `1234.50` in the Brazilian notation.
///
/// ```gleam
/// notation.parse("1.234,56", notation.brazilian)  // -> Ok(1234.56)
/// notation.parse("1234,56", notation.brazilian)   // -> Ok(1234.56)
/// notation.parse("12.34,5", notation.brazilian)
/// // -> Error(InvalidGrouping(position: 2))
/// ```
pub fn parse(text: String, notation: Notation) -> Result(Decimal, ParseError) {
  let bytes = string.byte_size(text)
  use <- bool.guard(bytes > max_text_bytes, Error(TextTooLong(bytes)))
  case string.to_graphemes(text) {
    [] -> Error(EmptyText)
    ["-", ..rest] -> parse_body(rest, 1, "-", notation)
    graphemes -> parse_body(graphemes, 0, "", notation)
  }
}

fn parse_body(
  graphemes: List(String),
  position: Int,
  sign: String,
  notation: Notation,
) -> Result(Decimal, ParseError) {
  use #(whole, position, rest) <- result.try(scan_whole(
    graphemes,
    position,
    notation,
  ))
  case rest {
    [] -> finish(sign, whole, "")
    [separator, ..after] if separator == notation.decimal_separator -> {
      let #(fraction, end, rest) = scan_digits(after, position + 1, "")
      case fraction, rest {
        "", [] -> Error(MissingDigits(position + 1))
        "", [character, ..] ->
          Error(UnexpectedCharacter(position + 1, character))
        _, [] -> finish(sign, whole, fraction)
        _, [character, ..] -> Error(UnexpectedCharacter(end, character))
      }
    }
    [character, ..] -> Error(UnexpectedCharacter(position, character))
  }
}

/// The integer digits without separators, the position after them and the
/// rest of the text.
fn scan_whole(
  graphemes: List(String),
  position: Int,
  notation: Notation,
) -> Result(#(String, Int, List(String)), ParseError) {
  let #(lead, after_lead, rest) = scan_digits(graphemes, position, "")
  case lead, rest {
    "", [] -> Error(MissingDigits(position))
    "", [character, ..] -> Error(UnexpectedCharacter(position, character))
    // A first group of more than three digits, or one that starts with a
    // zero (`0.500`, `01.234`), is not a grouped number.
    "0" <> _, [separator, ..] if separator == notation.group_separator ->
      Error(InvalidGrouping(after_lead))
    _, [separator, ..] if separator == notation.group_separator ->
      case after_lead - position > 3 {
        True -> Error(InvalidGrouping(after_lead))
        False -> scan_groups(rest, after_lead, lead, notation)
      }
    _, _ -> Ok(#(lead, after_lead, rest))
  }
}

/// Reads `(group-separator digit digit digit)*`.
fn scan_groups(
  graphemes: List(String),
  position: Int,
  digits: String,
  notation: Notation,
) -> Result(#(String, Int, List(String)), ParseError) {
  case graphemes {
    [separator, ..after] if separator == notation.group_separator -> {
      let #(group, end, rest) = scan_digits(after, position + 1, "")
      case end - position - 1 == 3 {
        True -> scan_groups(rest, end, digits <> group, notation)
        False -> Error(InvalidGrouping(position))
      }
    }
    _ -> Ok(#(digits, position, graphemes))
  }
}

fn scan_digits(
  graphemes: List(String),
  position: Int,
  digits: String,
) -> #(String, Int, List(String)) {
  case graphemes {
    [grapheme, ..rest] ->
      case is_digit(grapheme) {
        True -> scan_digits(rest, position + 1, digits <> grapheme)
        False -> #(digits, position, graphemes)
      }
    [] -> #(digits, position, [])
  }
}

fn is_digit(grapheme: String) -> Bool {
  case grapheme {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

/// Reads the canonical text without its leading zeros, so a long but valid
/// input is judged by its digits rather than by its length.
fn finish(
  sign: String,
  whole: String,
  fraction: String,
) -> Result(Decimal, ParseError) {
  let fraction_count = string.byte_size(fraction)
  use <- bool.guard(
    fraction_count > glecimal.max_scale,
    Error(TooManyFractionDigits(fraction_count)),
  )
  let whole = case drop_leading_zeros(whole) {
    "" -> "0"
    digits -> digits
  }
  let digits = case whole, drop_leading_zeros(fraction) {
    "0", significant -> string.byte_size(significant)
    _, _ -> string.byte_size(whole) + fraction_count
  }
  use <- bool.guard(digits > glecimal.max_digits, Error(TooManyDigits(digits)))
  glecimal.parse(case fraction {
    "" -> sign <> whole
    _ -> sign <> whole <> "." <> fraction
  })
}

fn drop_leading_zeros(digits: String) -> String {
  case digits {
    "0" <> rest -> drop_leading_zeros(rest)
    _ -> digits
  }
}
