# glecimal roadmap

Where glecimal is going. The [README](README.md) is the reference for what
ships today; this file covers the principles every release keeps and what
comes next.

## Principles

1. **Exact, or explicit about it.** A result is exact, or it was rounded once
   with a rounding the caller named. Wrong output is a defect, whatever the
   input.
2. **No floats.** No value passes through binary floating point, in the API or
   inside it.
3. **Bounded.** Every value and every operation has a stated bound, and a
   result past it is an error, never a truncated number.
4. **The same everywhere.** Erlang and JavaScript give identical results, and
   the vectors prove it on both.
5. **Pure Gleam.** Every line is Gleam, with no FFI. When a primitive is
   missing, the approach changes; no shim is added.
6. **An independent oracle.** Every operation is checked against Python's
   `decimal` module, and each new operation brings its vectors.
7. **The README is the contract.** Its examples are tests.

## 1.0: shipped

Decimals with seven named roundings, division and powers rounded once,
allocation that adds up, `Money` over the ISO 4217 currencies, localized
display and input, JSON decoders, and PostgreSQL through text.

## 1.1: shipped

Currency conversion rounded once, `money.zero`, `money.format`, and division
with an exact remainder.

## 1.2: shipped

Notations named by locale, with CLDR's separators and `for_locale`.

## Next

- **More of CLDR's number formats**, so that more locales fit: a minimum
  of two grouping digits (`es-ES`, `it-IT`, `pt-PT`), Indian grouping
  (`en-IN`) and the Unicode minus (`sv-SE`, `fi-FI`).

- **Exact YAML numbers with yamleam.** A yamleam decoder that hands over a
  number as written, so `rate: 0.0725` in a configuration file decodes
  exactly; this needs a yamleam release first.

- **The ISO 4217 list.** Each amendment ships as a minor release
  (`scripts/currencies.py --refresh`). New codes are added; a withdrawn code
  keeps a deprecated constant, and `from_code` still reads it, so no release
  breaks a build or an old record. A change in a code's minor units changes
  amounts, so it ships as a major release.
- **More notations** as real users need them, such as Indian digit grouping
  (`12,34,567.89`), which groups by two after the first three.

Requests for operations go through the same principles: an operation that would
need a float, or a result without a bound, does not fit.
