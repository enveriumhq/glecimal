# Changelog

## 1.0.0

The first release.

- `glecimal`: exact decimals of up to 128 digits and scale 64, on Erlang and
  JavaScript. `parse` reads every value a decimal holds and says where and why
  it refused, so `to_string` and `parse` are inverses. Exact addition,
  subtraction and multiplication; products, division, rounding and powers
  rounded once with one of seven named roundings; `rescale` and `normalize`;
  `compare`, `min` and `max`; `allocate` and `split`, which always add up;
  integers and minor units within ±(2^53 − 1); one error type for every
  operation; a JSON decoder that reads strings only.
- `glecimal/notation`: display formatting, and strict parsing of localized
  input, with Brazilian, English and plain notations or custom separators.
- `glecimal/currency`: the 165 ISO 4217 currencies with minor units, as
  published on 2026-09-17, in a table that only grows.
- `glecimal/money`: amounts at their currency's scale that never mix
  currencies, with exact arithmetic, products rounded once, allocation, an
  audit text form and a JSON decoder.
