#!/usr/bin/env bash
# The whole local gate: formatting, a warnings-as-errors build and the tests on
# both targets, the vectors and the currency table against their generators,
# and the source ratchet. Run from anywhere.
set -euo pipefail
cd "$(dirname "$0")/.."

gleam format --check src test
for target in erlang javascript; do
  echo "== $target"
  gleam build --target "$target" --warnings-as-errors
  gleam test --target "$target"
done
python3 -I scripts/vectors.py --check
python3 -I scripts/currencies.py --check
python3 -I scripts/check-site.py
scripts/check-gleam.sh
gleam docs build >/dev/null
echo "check: all passed"
