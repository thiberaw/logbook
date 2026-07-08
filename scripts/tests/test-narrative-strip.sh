#!/usr/bin/env bash
# =============================================================================
# test-narrative-strip.sh — JSON extraction/stripping from session notes  [TEST]
#
# WHAT IT TESTS:  Two helpers from lib/session-utils.sh that split a session's
#                 markdown "narrative" into two parts:
#                   - narrative_extract_json  -> pulls out the trailing JSON blob
#                   - narrative_strip_json    -> returns the prose with that JSON removed
#                 It checks they handle: bare JSON, fenced ```json blocks (the
#                 original bug — fenced JSON used to leak into reviewed/*.md),
#                 missing JSON, trailing blank lines, and malformed JSON.
# HOW TO RUN:     `bash scripts/tests/test-narrative-strip.sh`
#                 Each check prints "  PASS: <name>" or "  FAIL: <name>"; the
#                 script ends with a final PASS line, or exits non-zero on any FAIL.
# =============================================================================
set -euo pipefail   # Strict mode: -e abort on error, -u unset var=error, -o pipefail propagates pipe failures.

# Locate the scripts/ dir (one level up from tests/) and load the functions
# under test. `"${BASH_SOURCE[0]}"` is this file's path; `/..` then `pwd` make
# it absolute, so the source works regardless of the caller's directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/session-utils.sh"

FAILS=0   # running count of failed assertions; checked at the end

# assert_eq <name> <expected> <actual>: compare two strings and report PASS/FAIL.
# On mismatch it prints both values via `printf '%q'` (which shows whitespace and
# newlines in an unambiguous, quoted form) and bumps the failure counter.
assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then       # plain string equality
    echo "  PASS: $name"
  else
    echo "  FAIL: $name"
    echo "    expected: $(printf '%q' "$expected")"
    echo "    actual:   $(printf '%q' "$actual")"
    FAILS=$((FAILS + 1))                      # arithmetic increment
  fi
}

echo "Testing narrative_extract_json / narrative_strip_json..."

# Each test below defines a sample narrative (a here-string in a variable), then
# asserts what extract/strip should return. `$(func "$VAR")` runs the function in
# a subshell and captures its stdout for comparison.

# Case 1: bare JSON on the last line (the path that already worked).
# extract should return exactly that JSON object; strip should return the prose
# with the JSON line gone. A failure here means the basic happy path regressed.
N1='## Goal
Fix the bug.

## Improvement Signal
Add a rule.

{"task_type": "bugfix", "outcome": "success"}'
assert_eq "bare/extract" '{"task_type": "bugfix", "outcome": "success"}' "$(narrative_extract_json "$N1")"
EXPECTED1='## Goal
Fix the bug.

## Improvement Signal
Add a rule.'
assert_eq "bare/strip" "$EXPECTED1" "$(narrative_strip_json "$N1")"

# Case 2: fenced JSON inside a ```json ... ``` block — this is the original bug.
# extract must still find the JSON, and strip must remove the WHOLE fenced block
# (fences included). If strip failed, the ```json fences would leak into the
# published reviewed/*.md files.
N2='## Goal
Fix the bug.

## Improvement Signal
Add a rule.

```json
{"task_type": "review", "outcome": "success"}
```'
assert_eq "fenced/extract" '{"task_type": "review", "outcome": "success"}' "$(narrative_extract_json "$N2")"
EXPECTED2='## Goal
Fix the bug.

## Improvement Signal
Add a rule.'
assert_eq "fenced/strip" "$EXPECTED2" "$(narrative_strip_json "$N2")"

# Case 3: no JSON at all. extract should return "" (nothing to pull out) and
# strip should return the narrative completely unchanged. A failure would mean
# the helpers mangle plain prose that has no JSON.
N3='## Goal
Just a note.'
assert_eq "none/extract" "" "$(narrative_extract_json "$N3")"
assert_eq "none/strip" "$N3" "$(narrative_strip_json "$N3")"

# Case 4: fenced JSON followed by a trailing blank line after the closing fence.
# Verifies strip still removes the whole block (and the dangling blank line)
# rather than being thrown off by trailing whitespace at the end of the text.
N4='## Improvement Signal
Add a rule.

```json
{"task_type": "feature", "outcome": "partial"}
```
'
assert_eq "fenced-trailing/extract" '{"task_type": "feature", "outcome": "partial"}' "$(narrative_extract_json "$N4")"
EXPECTED4='## Improvement Signal
Add a rule.'
assert_eq "fenced-trailing/strip" "$EXPECTED4" "$(narrative_strip_json "$N4")"

# Case 5: malformed JSON (missing quotes). extract must return "" because the
# blob isn't valid JSON — we don't want garbage propagated downstream. (strip's
# behaviour here is intentionally not asserted; see the note after the case.)
N5='## Improvement Signal
Bad JSON.

{"task_type": "review", outcome: success}'
assert_eq "malformed/extract" "" "$(narrative_extract_json "$N5")"
# Note: strip still removes the line containing "task_type" — that is fine,
# malformed JSON would be useless in the final markdown anyway.

# Final verdict: if no assertion bumped the counter, report overall PASS;
# otherwise print how many failed and exit non-zero so a CI runner sees failure.
if [ "$FAILS" -eq 0 ]; then                  # `-eq` is numeric equality
  echo "PASS: narrative strip handles bare, fenced, and missing JSON"
else
  echo "FAIL: $FAILS assertion(s) failed"
  exit 1
fi
