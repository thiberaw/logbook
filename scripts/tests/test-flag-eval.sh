#!/usr/bin/env bash
# =============================================================================
# test-flag-eval.sh — FREE deterministic unit test of the flag-eval engine [TEST]
#
# WHAT IT TESTS: the engine's pure logic (print_scorecard arithmetic, n/a
#   guards, _majority_label voting) WITHOUT any real model call — VERDICT_FN is
#   stubbed. Runs in the default sweep (no RUN_LLM_TESTS gate) so the harness's
#   own math stays regression-safe at zero cost and zero flake. The expensive
#   real-model eval lives in test-flag-analysis.sh.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/flag-analysis.sh"
source "$SCRIPT_DIR/lib/flag-eval.sh"

FAILS=0
assert_contains() { # name haystack needle
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "  PASS: $1"; else
    echo "  FAIL: $1"; echo "    wanted substring: $3"; echo "    in: $2"; FAILS=$((FAILS+1)); fi
}
assert_eq() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  PASS: $1"; else
    echo "  FAIL: $1 (expected '$2' got '$3')"; FAILS=$((FAILS+1)); fi
}

echo "Testing print_scorecard arithmetic..."
# TP=5 FP=0 FN=1 TN=1 invalid=0 -> precision 5/5=1.00, recall 5/6=0.83, accuracy 6/7=0.86
OUT=$(print_scorecard 5 0 1 1 0 claude-sonnet-4-6)
assert_contains "precision fraction" "$OUT" "precision 5/5 = 1.00"
assert_contains "recall fraction"    "$OUT" "recall 5/6 = 0.83"
assert_contains "accuracy fraction"  "$OUT" "accuracy 6/7 = 0.86"
assert_contains "directional banner" "$OUT" "DIRECTIONAL ONLY"

echo "Testing print_scorecard zero-denominator guards..."
# No clear-actual and no confirm-pred edge: TP=0 FP=0 FN=0 TN=0 -> all n/a
OUT0=$(print_scorecard 0 0 0 0 0 claude-sonnet-4-6)
assert_contains "precision n/a" "$OUT0" "precision n/a"
assert_contains "recall n/a"    "$OUT0" "recall n/a"
assert_contains "accuracy n/a"  "$OUT0" "accuracy n/a"

echo "Testing _majority_label short-circuit on 2 agreeing..."
# Stub that always returns confirm - should short-circuit on 2nd call
_always_confirm() { echo "confirm"; }
VERDICT_FN=_always_confirm
assert_eq "2x confirm -> confirm" "confirm" "$(_majority_label 'p')"

echo "Testing _majority_label 3-way tie fallback (confirm wins)..."
# Use a temp file to persist counter across subshell calls
test_file=$(mktemp)
echo "0" > "$test_file"

_file_based_verdict() {
  local idx=$(cat "$test_file")
  case "$idx" in
    0) echo "clear" ;;
    1) echo "invalid" ;;
    *) echo "confirm" ;;
  esac
  echo $((idx + 1)) > "$test_file"
}

VERDICT_FN=_file_based_verdict
echo "0" > "$test_file"  # Reset
result=$(_majority_label 'p')
rm -f "$test_file"
assert_eq "tie -> confirm" "confirm" "$result"

echo "Testing run_corpus parse + gate (stubbed model)..."
# Stub: return the label named in the prompt's "WANT:<label>" marker.
_marker_verdict() {
  case "$1" in
    *WANT:confirm*) echo confirm ;;
    *WANT:clear*)   echo clear ;;
    *)              echo invalid ;;
  esac
}
VERDICT_FN=_marker_verdict

TMPDIR_C=$(mktemp -d)
echo "stub fixture body" > "$TMPDIR_C/a.condensed.txt"
echo "stub fixture body" > "$TMPDIR_C/b.condensed.txt"
FIXTURES="$TMPDIR_C"
# Row metric cols are arbitrary; flag_reasons carries the WANT marker.
printf '%s\tconfirm\tWANT:confirm\tp\tmain\t1\t0.1\t1\t1\t0\t0\n' "a.condensed.txt"  > "$TMPDIR_C/m.tsv"
printf '%s\tclear\tWANT:clear\tp\tmain\t1\t0.1\t1\t1\t0\t0\n'     "b.condensed.txt" >> "$TMPDIR_C/m.tsv"
OUT=$(run_corpus "$TMPDIR_C/m.tsv"); RC=$?
assert_eq "all-correct gate passes" "0" "$RC"
assert_contains "scorecard printed for N=2 corpus" "$OUT" "corpus: 2 fixtures"

# A regressing corpus: expected confirm but stub returns clear.
printf '%s\tconfirm\tWANT:clear\tp\tmain\t1\t0.1\t1\t1\t0\t0\n' "a.condensed.txt" > "$TMPDIR_C/bad.tsv"
OUT=$(run_corpus "$TMPDIR_C/bad.tsv"); RC=$?
assert_eq "regression gate fails" "1" "$RC"
assert_contains "regression reported" "$OUT" "GATE: FAIL"

# Arity guard: a 10-column row is a hard error.
printf 'x.condensed.txt\tconfirm\tWANT:confirm\tp\tmain\t1\t0.1\t1\t1\t0\n' > "$TMPDIR_C/short.tsv"
run_corpus "$TMPDIR_C/short.tsv" >/dev/null 2>&1; RC=$?
assert_eq "arity guard rejects 10-col row" "1" "$RC"
rm -rf "$TMPDIR_C"

if [ "$FAILS" -eq 0 ]; then echo "PASS: flag-eval engine logic"; else echo "FAIL: $FAILS assertion(s)"; exit 1; fi
