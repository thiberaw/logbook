#!/usr/bin/env bash
# =============================================================================
# test-record-transcript.sh — hermetic test for scripts/record-transcript.sh  [TEST]
#
# WHAT IT TESTS:  the generic external-transcript ingest path — that handing a
#                 Claude Code-format transcript to `record-transcript` produces
#                 a row with the SAME metrics a CLI session would get (cost,
#                 turns, tool calls, errors, files, duration), that --source
#                 tags the row name, re-running is idempotent (no double tag),
#                 and a missing file fails loudly.
# HOW IT STAYS HERMETIC:
#                 - LOGBOOK_DATA_DIR points at a throwaway dir (own DB)
#                 - `claude` is stubbed on PATH so the worker's narrative call
#                   makes no network/LLM request
#                 - a fresh articles cache suppresses the background refresh
# HOW TO RUN:     `bash scripts/tests/test-record-transcript.sh`
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo scripts/

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
assert_eq() {         # <name> <expected> <actual>
  local name="$1" exp="$2" act="$3"
  if [ "$exp" = "$act" ]; then
    echo "  PASS: $name"
  else
    echo "  FAIL: $name"; echo "    expected: $exp"; echo "    actual:   $act"
    FAILS=$((FAILS + 1))
  fi
}
assert_contains() {   # <name> <needle> <haystack>
  local name="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then echo "  PASS: $name"
  else echo "  FAIL: $name"; echo "    missing: $needle"; echo "    in: $haystack"; FAILS=$((FAILS + 1)); fi
}
assert_absent() {     # <name> <needle> <haystack>
  local name="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  FAIL: $name"; echo "    unexpectedly present: $needle"; FAILS=$((FAILS + 1))
  else echo "  PASS: $name"; fi
}

# --- hermetic environment ----------------------------------------------------
export LOGBOOK_DATA_DIR="$TMP/data"
DB="$LOGBOOK_DATA_DIR/.state/sessions.db"
mkdir -p "$LOGBOOK_DATA_DIR/.state"
# Fresh articles cache → the worker's 12h-staleness check skips the background
# fetch (which would otherwise try the network).
echo '[]' > "$LOGBOOK_DATA_DIR/.state/articles-cache.json"

# Stub `claude` so the worker's narrative call is offline and deterministic.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null   # consume the prompt on stdin
result='## Goal
Test.

## Approach
Made the change.

## Outcome
Change applied.

## Friction
None.

## Improvement Signal
None.
{"task_type": "refactor", "outcome": "success"}'
jq -n --arg r "$result" '{result:$r, total_cost_usd:0.0001}'
STUB
chmod +x "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH"

# Working dir referenced by the fixture (a plain dir, not a git repo → the
# project name falls back to the directory basename "proj").
PROJ="$TMP/proj"
mkdir -p "$PROJ"

# --- fixture transcript ------------------------------------------------------
# A minimal Claude Code-format JSONL exercising every metric:
#   2 assistant text blocks   → turns = 2
#   1 external user prompt     → first_prompt captured
#   1 Edit tool_use            → tool_calls = 1, files_modified = 1
#   1 tool_result is_error     → tool_errors = 1
#   usage on 2 opus messages   → cost = (1200*5 + 600*25)/1e6 = 0.021
#   timestamps 10:00 → 10:03   → duration = 3 min
SID="testsess-0000-4000-8000-000000000001"
FIX="$TMP/$SID.jsonl"
cat > "$FIX" <<JSONL
{"type":"user","userType":"external","uuid":"u1","sessionId":"$SID","cwd":"$PROJ","gitBranch":"main","timestamp":"2026-10-20T10:00:00.000Z","message":{"role":"user","content":"Please refactor the parser module"}}
{"type":"assistant","requestId":"req1","sessionId":"$SID","cwd":"$PROJ","timestamp":"2026-10-20T10:01:00.000Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"I will refactor it now."},{"type":"tool_use","name":"Edit","input":{"file_path":"$PROJ/parser.py"}}]}}
{"type":"user","uuid":"u2","sessionId":"$SID","cwd":"$PROJ","timestamp":"2026-10-20T10:02:00.000Z","message":{"role":"user","content":[{"type":"tool_result","is_error":true,"content":"error: boom"}]}}
{"type":"assistant","requestId":"req2","sessionId":"$SID","cwd":"$PROJ","timestamp":"2026-10-20T10:03:00.000Z","message":{"id":"m2","model":"claude-opus-4-8","usage":{"input_tokens":200,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"Fixed the error and retried."}]}}
JSONL

EXPECTED_DATE=$(date -d "2026-10-20T10:00:00.000Z" +%Y-%m-%d)

col() { sqlite3 "$DB" "SELECT $1 FROM sessions WHERE session_id='$SID';"; }

# --- 1) ingest with --source -------------------------------------------------
echo "== record-transcript with --source =="
OUT=$(bash "$SCRIPT_DIR/record-transcript.sh" "$FIX" --source codecompanion)

assert_eq       "turns parsed"          "2"   "$(col turns)"
assert_eq       "tool_calls parsed"     "1"   "$(col tool_calls)"
assert_eq       "tool_errors parsed"    "1"   "$(col tool_errors)"
assert_eq       "files_modified parsed" "1"   "$(col files_modified)"
assert_eq       "duration parsed"       "3"   "$(col duration)"
assert_eq       "status done"           "done" "$(col status)"
assert_eq       "date = local first-ts" "$EXPECTED_DATE" "$(col date)"

COST=$(col cost)
COST_OK=$(LC_ALL=C awk "BEGIN {print ($COST > 0.0205 && $COST < 0.0215) ? \"yes\" : \"no\"}")
assert_eq       "cost computed (~0.021)" "yes" "$COST_OK"

NAME=$(col name)
assert_contains "project from cwd basename" "[proj]" "$NAME"
assert_contains "source tag in name"        "[codecompanion]" "$NAME"
assert_contains "confirmation printed"      "recorded:" "$OUT"

# --- 2) re-run WITHOUT --source is idempotent (single row, no tag) -----------
echo "== re-run without --source =="
bash "$SCRIPT_DIR/record-transcript.sh" "$FIX" >/dev/null
ROWS=$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions WHERE session_id='$SID';")
assert_eq       "still exactly one row"  "1" "$ROWS"
assert_absent   "tag gone after re-run (no double-tag)" "[codecompanion]" "$(col name)"

# --- 3) missing file fails loudly --------------------------------------------
echo "== missing file =="
if bash "$SCRIPT_DIR/record-transcript.sh" "$TMP/does-not-exist.jsonl" >/dev/null 2>&1; then
  echo "  FAIL: missing file should exit non-zero"; FAILS=$((FAILS + 1))
else
  echo "  PASS: missing file exits non-zero"
fi

# --- 4) duration is the transcript span, NOT wall-clock since start ----------
# Regression: the worker once used `now` as the session END, so running it after
# the fact (a backfill, or any delayed ingest) measured the gap SINCE the session
# instead of the session (a day-old row read 1807m instead of its real ~2h). The
# END must come from the transcript's LAST timestamp. Here the fixture is dated in
# the past and a stale started_at is seeded: with the bug duration is thousands of
# minutes (now − start); fixed it is start(09:58) → last-ts(10:03) = 5.
echo "== duration from transcript span, not now =="
SID2="testsess-0000-4000-8000-000000000002"
FIX2="$TMP/$SID2.jsonl"
cat > "$FIX2" <<JSONL
{"type":"user","userType":"external","uuid":"v1","sessionId":"$SID2","cwd":"$PROJ","gitBranch":"main","timestamp":"2026-10-20T10:00:00.000Z","message":{"role":"user","content":"Please refactor the parser module"}}
{"type":"assistant","requestId":"r1","sessionId":"$SID2","cwd":"$PROJ","timestamp":"2026-10-20T10:01:00.000Z","message":{"id":"n1","model":"claude-opus-4-8","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"Working on it."}]}}
{"type":"assistant","requestId":"r2","sessionId":"$SID2","cwd":"$PROJ","timestamp":"2026-10-20T10:03:00.000Z","message":{"id":"n2","model":"claude-opus-4-8","usage":{"input_tokens":200,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"Done."}]}}
JSONL
# Seed a stale SessionStart (same past day, two minutes before first activity).
echo "{\"$SID2\":{\"started_at\":\"2026-10-20T09:58:00.000Z\"}}" > "$LOGBOOK_DATA_DIR/.state/session-starts.json"
bash "$SCRIPT_DIR/record-transcript.sh" "$FIX2" >/dev/null
DUR2=$(sqlite3 "$DB" "SELECT duration FROM sessions WHERE session_id='$SID2';")
assert_eq "duration = seeded start → transcript end (5), not now-based" "5" "$DUR2"

echo ""
if [ "$FAILS" -eq 0 ]; then
  echo "test-record-transcript: ALL PASS"
else
  echo "test-record-transcript: $FAILS FAILURE(S)"; exit 1
fi
