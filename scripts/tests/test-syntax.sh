#!/usr/bin/env bash
# =============================================================================
# test-syntax.sh — bash syntax check over every shell script  [TEST]
#
# WHAT IT TESTS:  that every scripts/**/*.sh parses (`bash -n`). This is a
#                 cheap, total guard against the failure that killed the
#                 session-tracking pipeline 06-26..29: commit f1e2082 added
#                 unescaped double-quotes inside session-end-worker.sh's
#                 NARRATIVE_PROMPT="..." string, breaking the quoting through
#                 to EOF. `bash -n` catches that class instantly, but no test
#                 ran it — so the worker crashed on every session-end for 3
#                 days, silently. A syntax error anywhere here fails CI now.
# HOW TO RUN:     `bash scripts/tests/test-syntax.sh`
#                 Walks scripts/ for *.sh files and bash -n's each; prints
#                 PASS/FAIL per file and a final verdict (exit 1 on any fail).
# =============================================================================
set -uo pipefail

# scripts/ root (this file lives in scripts/tests/).
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FAILS=0
CHECKED=0

echo "Syntax-checking every scripts/**/*.sh ..."

# -print0 / read -d '' handles any path safely. Sorted for stable output.
while IFS= read -r -d '' f; do
  CHECKED=$((CHECKED + 1))
  if err=$(bash -n "$f" 2>&1); then
    echo "  PASS: ${f#"$SCRIPTS_DIR"/}"
  else
    echo "  FAIL: ${f#"$SCRIPTS_DIR"/}"
    echo "    $err"
    FAILS=$((FAILS + 1))
  fi
done < <(find "$SCRIPTS_DIR" -type f -name '*.sh' -print0 | sort -z)

echo ""
if [ "$FAILS" -eq 0 ]; then
  echo "PASS: all $CHECKED shell scripts parse cleanly"
else
  echo "FAIL: $FAILS of $CHECKED shell script(s) have syntax errors"
  exit 1
fi
