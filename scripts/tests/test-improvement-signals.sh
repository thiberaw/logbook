#!/usr/bin/env bash
# =============================================================================
# test-improvement-signals.sh — render_improvement_signals coloring/structure  [TEST]
#
# WHAT IT TESTS:  render_improvement_signals (TUI) and render_improvement_signals_md
#                 (markdown) from lib/session-utils.sh. The morning review went
#                 "flat" for weeks because its ORANGE warning
#                 branch fired ONLY on the LLM `flagged` bit, which collapsed to
#                 ~0%. The fix made orange fire on deterministic, flag-independent
#                 signals too. This test pins that behaviour so it can't silently
#                 regress to flag-only again:
#                   - flagged+issue            -> orange header + ⚠ issue + green rec
#                   - outcome=partial (no flag) -> orange header + ⚠ outcome: partial
#                   - narrative_confidence=low  -> orange header + ⚠ unverified
#                   - clean success + signal    -> grey header + green rec, no ⚠
#                   - clean, no signal          -> dropped entirely
#                 It also checks the ## Goal context line is extracted (not the
#                 raw "## Goal" heading) and 0-turn no-op rows stay grey.
# HOW TO RUN:     `bash scripts/tests/test-improvement-signals.sh`
#                 No LLM calls — pure function over crafted JSON. ANSI colour is
#                 mapped to [ORANGE]/[GREEN]/[GREY] tags before asserting so the
#                 test reads the colour, not just the text.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/session-utils.sh"

FAILS=0

# tagged_tui <sessions_json>: run the TUI renderer and replace the gum colour
# escape sequences with readable [ORANGE]/[GREEN]/[GREY] tags, dropping any other
# ANSI. This lets assertions check WHICH colour a line was printed in, not just
# its text. CLICOLOR_FORCE=1 makes gum emit colour even though our stdout is a
# pipe (no TTY); lipgloss then downsamples the 256-colour values to 16-colour
# ANSI (214->93, 82->92, 245->90), optionally bold-prefixed (1;). We map both
# the downsampled and the true 256-colour forms so the test survives either
# terminal profile. stderr is dropped (it carries shell -x trace, not output).
tagged_tui() {
  CLICOLOR_FORCE=1 render_improvement_signals "$1" 2>/dev/null | sed -E '
    s/\x1b\[(1;)?(38;5;214|93)m/[ORANGE]/g;
    s/\x1b\[(1;)?(38;5;82|92)m/[GREEN]/g;
    s/\x1b\[(1;)?(38;5;245|90)m/[GREY]/g;
    s/\x1b\[[0-9;]*m//g'
}

# assert_contains <name> <haystack> <needle>
assert_contains() {
  local name="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then
    echo "  PASS: $name"
  else
    echo "  FAIL: $name"
    echo "    expected to find: $(printf '%q' "$needle")"
    echo "    in: $(printf '%q' "$hay")"
    FAILS=$((FAILS + 1))
  fi
}

# assert_absent <name> <haystack> <needle>
assert_absent() {
  local name="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then
    echo "  FAIL: $name (found unexpected: $(printf '%q' "$needle"))"
    FAILS=$((FAILS + 1))
  else
    echo "  PASS: $name"
  fi
}

echo "Testing render_improvement_signals (TUI + markdown)..."

# --- Case 1: flagged + issue → orange header, orange issue, green suggestion ---
S1='[{"Project":"app-front","Flagged":1,"Issue":"entered an exploration spiral",
  "Suggestion":"add a CLAUDE.md rule","Task_Type":"review","Outcome":"success","Turns":15,"Tool_Calls":30,
  "Description":"## Goal\nReview PR #1.\n\n## Improvement Signal\nNone."}]'
OUT1=$(tagged_tui "$S1")
assert_contains "flagged/orange-header"  "$OUT1" "[ORANGE]  ⚠ app-front [review → success]"
assert_contains "flagged/orange-issue"   "$OUT1" "[ORANGE]    entered an exploration spiral"
assert_contains "flagged/green-rec"      "$OUT1" "[GREEN]    → add a CLAUDE.md rule"
MD1=$(render_improvement_signals_md "$S1")
assert_contains "flagged/md-warning"     "$MD1" "  - ⚠ entered an exploration spiral"
assert_contains "flagged/md-rec"         "$MD1" "  - → add a CLAUDE.md rule"

# --- Case 2: NOT flagged, outcome=partial → orange header + ⚠ outcome: partial ---
S2='[{"Project":"acme-app","Flagged":0,"Issue":"","Suggestion":"","Task_Type":"bugfix",
  "Outcome":"partial","Turns":15,"Tool_Calls":17,"Description":"## Goal\nFix the date filter.\n\n## Improvement Signal\nCheck the DTO first."}]'
OUT2=$(tagged_tui "$S2")
assert_contains "partial/orange-header"  "$OUT2" "[ORANGE]  ⚠ acme-app [bugfix → partial]"
assert_contains "partial/orange-warn"    "$OUT2" "[ORANGE]    outcome: partial"
assert_contains "partial/goal-context"   "$OUT2" "[GREY]    Fix the date filter."
assert_contains "partial/green-rec"      "$OUT2" "[GREEN]    → Check the DTO first."
assert_absent   "partial/no-raw-heading" "$OUT2" "## Goal"

# --- Case 3: NOT flagged, narrative_confidence=low → orange + ⚠ unverified ---
S3='[{"Project":"sdlc","Flagged":0,"Issue":"","Suggestion":"","Task_Type":"investigation",
  "Outcome":"success","Turns":41,"Tool_Calls":69,"Narrative_Confidence":"low","Narrative_Issues":"cites commit deadbee not found in repo",
  "Description":"## Goal\nInvestigate SUP-1.\n\n## Improvement Signal\nNone."}]'
OUT3=$(tagged_tui "$S3")
assert_contains "lowconf/orange-header"  "$OUT3" "[ORANGE]  ⚠ sdlc [investigation → success]"
assert_contains "lowconf/orange-warn"    "$OUT3" "[ORANGE]    unverified — cites commit deadbee not found in repo"

# --- Case 4: clean success WITH a signal → grey header + green rec, no orange ---
S4='[{"Project":"app-front","Flagged":0,"Issue":"","Suggestion":"","Task_Type":"feature",
  "Outcome":"success","Description":"## Goal\nShip the thing.\n\n## Improvement Signal\nUse the skill next time."}]'
OUT4=$(tagged_tui "$S4")
assert_contains "clean/grey-header"      "$OUT4" "[GREY]  app-front [feature → success]"
assert_contains "clean/green-rec"        "$OUT4" "[GREEN]    → Use the skill next time."
assert_absent   "clean/no-orange"        "$OUT4" "[ORANGE]"
assert_absent   "clean/no-warn-marker"   "$OUT4" "⚠"

# --- Case 5: clean success, NO signal → dropped entirely (empty output) ---
S5='[{"Project":"app-front","Flagged":0,"Issue":"","Suggestion":"","Task_Type":"feature",
  "Outcome":"success","Description":"## Goal\nQuiet session.\n\n## Improvement Signal\nNone."}]'
OUT5=$(tagged_tui "$S5")
if [ -z "$(printf '%s' "$OUT5" | tr -d '[:space:]')" ]; then
  echo "  PASS: clean-nosignal/dropped"
else
  echo "  FAIL: clean-nosignal/dropped — expected empty, got: $(printf '%q' "$OUT5")"
  FAILS=$((FAILS + 1))
fi

# --- Case 6: 0-turn/0-call no-op with outcome=abandoned → NOT orange, dropped ---
# An open-then-/exit session attempted nothing; its "abandoned" label is the
# cosmetic no-op shape, not friction. With no signal it must be dropped entirely
# (matches the pre-fix behaviour for /exit rows), never painted orange.
S6='[{"Project":"acme-app","Flagged":0,"Issue":"","Suggestion":"","Task_Type":"other",
  "Outcome":"abandoned","Turns":0,"Tool_Calls":0,
  "Description":"## Goal\nOpened and exited.\n\n## Improvement Signal\nNone."}]'
OUT6=$(tagged_tui "$S6")
assert_absent   "noop-abandoned/no-orange" "$OUT6" "[ORANGE]"
if [ -z "$(printf '%s' "$OUT6" | tr -d '[:space:]')" ]; then
  echo "  PASS: noop-abandoned/dropped"
else
  echo "  FAIL: noop-abandoned/dropped — expected empty, got: $(printf '%q' "$OUT6")"
  FAILS=$((FAILS + 1))
fi

# --- Case 7: real session (turns>0) with outcome=abandoned → orange (not a no-op) ---
S7='[{"Project":"app-front","Flagged":0,"Issue":"","Suggestion":"","Task_Type":"bugfix",
  "Outcome":"abandoned","Turns":12,"Tool_Calls":20,
  "Description":"## Goal\nTried a fix.\n\n## Improvement Signal\nNone."}]'
OUT7=$(tagged_tui "$S7")
assert_contains "real-abandoned/orange-header" "$OUT7" "[ORANGE]  ⚠ app-front [bugfix → abandoned]"
assert_contains "real-abandoned/orange-warn"   "$OUT7" "[ORANGE]    outcome: abandoned"

if [ "$FAILS" -eq 0 ]; then
  echo "PASS: improvement-signals coloring + structure (orange is flag-independent)"
else
  echo "FAIL: $FAILS assertion(s) failed"
  exit 1
fi
