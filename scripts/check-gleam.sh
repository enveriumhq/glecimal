#!/usr/bin/env bash
# check-gleam.sh — mechanical ratchet for the `gleam` skill.
#
# The compiler already rejects non-exhaustive matches, missing fields, nil and
# misuse of opaque types; `gleam build --warnings-as-errors` fails on todo,
# unused code and ignored Results. This counts the shortcuts it accepts, per
# rule and file under src/, against a committed baseline. A key above its
# count is a new occurrence; a key below it is a fixed one still listed. Both
# fail, so removing one occurrence cannot make room for another.
#
#   ./check-gleam.sh --accept --reason TEXT  # adopt, or record growth deliberately
#   ./check-gleam.sh                         # check; non-zero on any difference
#   ./check-gleam.sh --shrink                # lower counts to current; never adds
#   ./check-gleam.sh --report                # report; execution errors still fail
#   ./check-gleam.sh --with-tools            # also run format, build, test (pass-fail)
#
# Options:
#   --dir DIR        project root, holding gleam.toml and src/ (default: cwd)
#   --baseline-file  path to the baseline (default: <dir>/.gleam-baseline.tsv)
#
# Requires: Bash 4+, rg with PCRE2; gleam for --with-tools. Tests live in
# test/, so scanning src/ alone excludes them exactly. Patterns skip comments
# and single-line strings; a multi-line string can still produce a false count.

set -uo pipefail
[ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo "error: Bash 4+ is required" >&2; exit 2; }

DIR="$(pwd)"
MODE="check"
REASON=""
WITH_TOOLS=0
BASELINE_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --accept)        MODE="accept" ;;
    --shrink)        MODE="shrink" ;;
    --reason)        REASON="${2?--reason needs text}"; shift ;;
    --report)        MODE="report" ;;
    --with-tools)    WITH_TOOLS=1 ;;
    --dir)           DIR="${2:?--dir needs a path}"; shift ;;
    --baseline-file) BASELINE_FILE="${2:?--baseline-file needs a path}"; shift ;;
    -h|--help)       sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

command -v rg >/dev/null 2>&1 || { echo "error: ripgrep (rg) is required" >&2; exit 2; }
[ -d "$DIR/src" ] || { echo "error: no src/ directory under $DIR" >&2; exit 2; }
BASELINE_FILE="${BASELINE_FILE:-$DIR/.gleam-baseline.tsv}"
REASON="${REASON//[$'\t\n']/ }"
if [ "$MODE" = accept ] && [ -z "${REASON// /}" ]; then
  echo "error: --accept needs --reason saying why these occurrences are accepted" >&2; exit 2
fi
if [ "$MODE" != accept ] && [ -n "$REASON" ]; then
  echo "error: --reason applies only to --accept" >&2; exit 2
fi

# The application's root module (src/<name>.gleam) is main: it may crash at startup.
PACKAGE_NAME="$(sed -n 's/^name *= *"\([a-z0-9_]*\)".*/\1/p' "$DIR/gleam.toml" 2>/dev/null | head -n 1)"

# Every rg call runs with the working directory at $DIR and searches src: rg
# anchors a --glob containing a `/` to the working directory, not the search
# path, so an absolute search root silently stops excluding.
RG=(--no-config --multiline --glob '*.gleam')

# Normalize rg's no-match status, but preserve regex, PCRE2, and I/O errors.
run_rg() {
  local status=0
  rg "$@" || status=$?
  case "$status" in
    0|1) return 0 ;;
    *) echo "error: ripgrep failed (exit $status)" >&2; return 2 ;;
  esac
}

# count_by_file PATTERN [extra rg args...] -> "file<TAB>matches" per matching file.
# The count sits after the last ':', so a ':' inside a path cannot split it wrongly.
count_by_file() {
  local pat="$1"; shift
  local output line
  output="$(cd "$DIR" && run_rg "${RG[@]}" "$@" --count-matches --with-filename --pcre2 "$pat" src)" || return 2
  [ -z "$output" ] && return 0
  while IFS= read -r line; do
    local file="${line%:*}"
    printf '%s\t%s\n' "${file#./}" "${line##*:}"
  done <<< "$output"
}

# locate PATTERN [extra rg args...] -> file:line:text for --report
locate() {
  local pat="$1"; shift
  # sed consumes the stream; head can turn a successful search into SIGPIPE.
  ( cd "$DIR" && run_rg "${RG[@]}" "$@" --line-number --pcre2 "$pat" src ) | sed -n '1,20p'
}

# --- rule definitions -------------------------------------------------------
# id | human label | pattern | extra rg args (space separated, may be empty)

IDS=(); LABELS=(); PATTERNS=(); EXTRAS=()
rule() { IDS+=("$1"); LABELS+=("$2"); PATTERNS+=("$3"); EXTRAS+=("${4:-}"); }

# Code before the match on its line, skipping comments and single-line strings.
NC='^(?:[^"/\n]|/(?!/)|"(?:[^"\\\n]|\\.)*")*?'

# A crash turns a typed refusal into a 500 and loses an actor's state.
ROOT_EXCLUDE=""
if [ -n "$PACKAGE_NAME" ]; then ROOT_EXCLUDE="--glob !$PACKAGE_NAME.gleam"; fi
rule crash_site \
  "let assert / assert / panic outside main and tests" \
  "${NC}"'(?:\blet\s+assert\b|(?<![\w.])assert\s|\bpanic\b)' \
  "$ROOT_EXCLUDE"

# A failure turned into a plausible value.
rule swallowed_failure \
  "result.unwrap / result.values / let _ =" \
  "${NC}"'(?:\bresult\.(?:lazy_)?unwrap\b|\bresult\.values\b|\blet\s+_\s*=)'

# Business quantities are exact; telemetry and layout floats carry a reason.
rule float \
  "Float type, float module, literal or operator" \
  "${NC}"'(?:\bFloat\b|\bfloat\.|\bto_float\b|(?<![\w.])\d[\d_]*\.\d|\s(?:[-+*/]|[<>]=?)\.\s)'

# A failure callers must distinguish needs a variant, not a message.
rule error_string \
  "Result(_, String)" \
  '\bResult\s*\((?:[^(),]|,|(\((?:[^()]++|(?1))*\)))*?,\s*String\s*,?\s*\)'

# Qualified calls show each function's owner and let search find every caller.
rule unqualified_import \
  "unqualified function or constant import" \
  '^import\s+[a-z][\w/]*\s*\.\s*\{(?:[^}]*,)?\s*(?!type\s)[a-z]\w*\s*(?:as\s+\w+\s*)?[,}]'

# FFI is a reviewed decision: @external declarations and foreign source files.
rule ffi \
  "@external declaration" \
  '^[ \t]*@external\s*\('

rule debug_echo \
  "echo (must be 0)" \
  "${NC}"'(?<![\w.])echo\b'

# Declared exceptions. Counted, not excused: a marker plus a raised baseline row.
rule gleam_exception \
  "declared GLEAM-EXCEPTION markers" \
  '//\s*GLEAM-EXCEPTION:'

# --- collect counts ---------------------------------------------------------

# COUNTS: total per rule. NOW: count per "rule<TAB>file", the unit the baseline holds.
declare -A COUNTS NOW
for i in "${!IDS[@]}"; do
  read -r -a extra <<< "${EXTRAS[$i]}"
  per_file="$(count_by_file "${PATTERNS[$i]}" ${extra[@]+"${extra[@]}"})" || exit 2
  total=0
  while IFS=$'\t' read -r file n; do
    [ -z "$file" ] && continue
    NOW["${IDS[$i]}"$'\t'"$file"]="$n"
    total=$((total + n))
  done <<< "$per_file"
  COUNTS["${IDS[$i]}"]="$total"
done

# Foreign source files count once each under ffi.
foreign_files="$(cd "$DIR" && run_rg --no-config --files --glob '*.erl' --glob '*.hrl' --glob '*.ex' \
    --glob '*.mjs' --glob '*.js' --glob '*.ts' src)" || exit 2
while IFS= read -r file; do
  [ -z "$file" ] && continue
  NOW["ffi"$'\t'"$file"]=1
  COUNTS[ffi]=$((COUNTS[ffi] + 1))
done <<< "$foreign_files"

# --- modes ------------------------------------------------------------------

declare -A BASE REASONS
KNOWN_RULES=" ${IDS[*]} "

read_baseline() {
  local rule key count reason trailing
  [ -f "$BASELINE_FILE" ] || return 0
  while IFS=$'\t' read -r rule key count reason trailing || [ -n "$rule" ]; do
    case "$rule" in ''|\#*) continue ;; esac
    if [[ "$KNOWN_RULES" != *" $rule "* ]]; then
      echo "error: unknown baseline rule: $rule — review and update the baseline" >&2; return 2
    fi
    if [ "$rule" = debug_echo ]; then
      echo "error: debug_echo cannot be baselined; it must be zero" >&2; return 2
    fi
    if [ -z "$key" ] || [[ ! "$count" =~ ^[1-9][0-9]{0,8}$ ]] || [ -z "${reason// /}" ] || [ -n "$trailing" ]; then
      echo "error: malformed baseline row: $rule $key" >&2; return 2
    fi
    if [ -n "${BASE[$rule$'\t'$key]:-}" ]; then
      echo "error: duplicate baseline entry: $rule $key" >&2; return 2
    fi
    BASE["$rule"$'\t'"$key"]="$count"
    REASONS["$rule"$'\t'"$key"]="$reason"
  done < "$BASELINE_FILE"
}

# write_baseline NAME_OF_COUNT_ARRAY NEW_REASON: rows for every key with a positive
# count; a key keeps its recorded reason unless its count rose.
write_baseline() {
  local -n counts_to_write="$1"
  local new_reason="$2" baseline_tmp key reason
  baseline_tmp="$(mktemp "${BASELINE_FILE}.tmp.XXXXXX")" || return 2
  {
    echo "# gleam baseline: rule, file, count, reason. Counts only fall;"
    echo "# growth goes through --accept with a reason, in its own reviewed commit."
    for key in "${!counts_to_write[@]}"; do
      [ "${counts_to_write[$key]}" -gt 0 ] || continue
      reason="${REASONS[$key]:-}"
      if [ "${counts_to_write[$key]}" -gt "${BASE[$key]:-0}" ]; then reason="$new_reason"; fi
      printf '%s\t%s\t%s\n' "$key" "${counts_to_write[$key]}" "$reason"
    done | sort
  } > "$baseline_tmp" || { rm -f -- "$baseline_tmp"; return 2; }
  mv -- "$baseline_tmp" "$BASELINE_FILE" || { rm -f -- "$baseline_tmp"; return 2; }
  echo "wrote $BASELINE_FILE"
}

# Keys above (GROWN) and below (STALE) their baseline count.
GROWN=(); STALE=()
compare() {
  local key
  for key in "${!NOW[@]}"; do
    if [ "${NOW[$key]}" -gt "${BASE[$key]:-0}" ]; then GROWN+=("$key"); fi
  done
  for key in "${!BASE[@]}"; do
    if [ "${NOW[$key]:-0}" -lt "${BASE[$key]}" ]; then STALE+=("$key"); fi
  done
}

print_keys() {
  local title="$1"; shift
  [ "$#" -gt 0 ] || return 0
  echo
  echo "$title"
  local key
  for key in "$@"; do
    printf '  %-24s %-48s now %s, baseline %s\n' "${key%%$'\t'*}" "${key#*$'\t'}" "${NOW[$key]:-0}" "${BASE[$key]:-0}"
  done | sort
}

summary() {
  local -A base_totals=()
  local key i
  for key in "${!BASE[@]}"; do
    base_totals["${key%%$'\t'*}"]=$(( ${base_totals["${key%%$'\t'*}"]:-0} + BASE[$key] ))
  done
  printf '%-24s %7s %7s  %s\n' RULE BASE NOW DESCRIPTION
  for i in "${!IDS[@]}"; do
    printf '%-24s %7s %7s  %s\n' "${IDS[$i]}" "${base_totals[${IDS[$i]}]:-0}" "${COUNTS[${IDS[$i]}]}" "${LABELS[$i]}"
  done
}

report() {
  printf '%-24s %7s  %s\n' RULE COUNT DESCRIPTION
  for i in "${!IDS[@]}"; do
    printf '%-24s %7s  %s\n' "${IDS[$i]}" "${COUNTS[${IDS[$i]}]}" "${LABELS[$i]}"
  done
  echo
  for i in "${!IDS[@]}"; do
    [ -z "${PATTERNS[$i]}" ] && continue
    [ "${COUNTS[${IDS[$i]}]}" = "0" ] && continue
    echo "--- ${IDS[$i]}: ${LABELS[$i]}"
    read -r -a extra <<< "${EXTRAS[$i]}"
    locate "${PATTERNS[$i]}" ${extra[@]+"${extra[@]}"} | sed 's/^/    /' || return 2
    echo
  done
  print_keys "Fixed but still listed (run --shrink):" ${STALE[@]+"${STALE[@]}"}
}

check() {
  if [ ! -f "$BASELINE_FILE" ]; then
    echo "error: no baseline at $BASELINE_FILE" >&2
    echo "       adopt with: $0 --accept --reason 'initial adoption' --dir $DIR   (then commit it)" >&2
    return 2
  fi
  summary
  print_keys "New occurrences (fix them, or --accept with a reason in its own commit):" ${GROWN[@]+"${GROWN[@]}"}
  print_keys "Fixed but still listed (run --shrink and commit the lower baseline):" ${STALE[@]+"${STALE[@]}"}
  if [ "${#GROWN[@]}" -gt 0 ] || [ "${#STALE[@]}" -gt 0 ]; then return 1; fi
  echo
  echo "Matches the baseline."
}

# shellcheck disable=SC2034  # lowered is read by name in write_baseline
shrink() {
  local -A lowered=()
  local key now
  for key in "${!BASE[@]}"; do
    now="${NOW[$key]:-0}"
    if [ "$now" -lt "${BASE[$key]}" ]; then lowered["$key"]="$now"; else lowered["$key"]="${BASE[$key]}"; fi
  done
  write_baseline lowered "" || return 2
  print_keys "Still above the baseline (fix them, or --accept with a reason):" ${GROWN[@]+"${GROWN[@]}"}
  [ "${#GROWN[@]}" -eq 0 ]
}

run_tools() {
  echo
  echo "=== pass/fail checks (not ratcheted) ==="
  local rc=0
  command -v gleam >/dev/null 2>&1 || { echo "error: --with-tools requires gleam" >&2; return 2; }
  ( cd "$DIR" && gleam format --check src test ) || { echo "  gleam format --check FAILED"; rc=1; }
  ( cd "$DIR" && gleam build --warnings-as-errors ) || { echo "  gleam build --warnings-as-errors FAILED"; rc=1; }
  ( cd "$DIR" && gleam test ) || { echo "  gleam test FAILED"; rc=1; }
  return $rc
}

rc=0
# An absolute prohibition cannot be grandfathered into a baseline. Reporting
# stays observational; it still exits non-zero if a check could not execute.
if [ "$MODE" != report ] && [ "${COUNTS[debug_echo]}" -ne 0 ]; then
  echo "error: echo is for debugging only; remove it (--report shows where)" >&2
  exit 1
fi
read_baseline || exit 2
compare
case "$MODE" in
  accept) write_baseline NOW "$REASON" || rc=$? ;;
  shrink) shrink || rc=$? ;;
  report) report || rc=$? ;;
  check)  check || rc=$? ;;
esac
if [ "$WITH_TOOLS" -eq 1 ]; then run_tools || rc=$?; fi
exit $rc
