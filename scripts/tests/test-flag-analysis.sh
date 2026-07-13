#!/usr/bin/env bash
# =============================================================================
# test-flag-analysis.sh — golden-corpus regression test for the flag analysis
#
# WHAT IT IS: the regression gate for the sonnet flag-analysis prompt in
#   lib/flag-analysis.sh. Three measurement incidents (a metrics inflation, a
#   gating regression, and a week of 100% flag-clearing) all
#   shipped through prompt/heuristic edits validated only by spot checks.
#   The corpus lives in fixtures/flag-corpus.tsv; the engine (run_corpus,
#   _majority_label, print_scorecard) lives in lib/flag-eval.sh.
#
# COST GATE: each case is 2-3 real sonnet calls (majority vote, ~$0.15 and
# ~1-2 min per case worst-case). The default
#   test sweep (`for t in scripts/tests/*.sh; do bash "$t"; done`) must stay
#   fast, free, and deterministic, so this test SKIPS unless RUN_LLM_TESTS=1.
#   Run it on EVERY change to lib/flag-analysis.sh (prompt or model) or to the
#   flag heuristics in session-end-worker.sh:
#       RUN_LLM_TESTS=1 bash scripts/tests/test-flag-analysis.sh
#
# GROWING THE CORPUS: morning-review now records flag verdicts (flag_feedback
#   column: 'correct'/'wrong'). When a verdict contradicts what this prompt
#   produces, freeze that session's condensed transcript into fixtures/ and
#   add a row to fixtures/flag-corpus.tsv via scripts/freeze-fixture.sh
#   (prints a row to paste; YOU set expected + flag_reasons). LLM verdicts
#   are not perfectly deterministic — a case that flips intermittently is
#   itself a signal the prompt is on a boundary.
# =============================================================================
set -euo pipefail

if [ "${RUN_LLM_TESTS:-0}" != "1" ]; then
  echo "SKIP test-flag-analysis — set RUN_LLM_TESTS=1 to run (2 real sonnet calls)"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/lib/flag-analysis.sh"
source "$SCRIPT_DIR/lib/flag-eval.sh"

# The golden corpus is PRIVATE user data living in the data dir — a fresh
# public clone has none, and that is not a failure.
if [ ! -f "$FIXTURES_DIR/flag-corpus.tsv" ]; then
  echo "no eval corpus at $FIXTURES_DIR — skipping"
  exit 0
fi

FIXTURES="$FIXTURES_DIR"   # run_corpus resolves fixture files against $FIXTURES
run_corpus "$FIXTURES_DIR/flag-corpus.tsv"
