#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# The live registry is user data in the data dir; validate it when present
# (env-overridable via WATCH_ITEMS_FILE), skip silently on a fresh clone.
# The rendering assertions below run against a temp registry either way.
source "$SCRIPT_DIR/config.sh" >/dev/null 2>&1 || true
REG="${WATCH_ITEMS_FILE:-${DOCS_DIR:-}/watch-items.json}"
if [ -f "$REG" ]; then
  jq -e 'type=="array" and length>0' "$REG" >/dev/null && ok "registry is a non-empty array" || bad "registry not a non-empty array"
  jq -e 'all(.[]; has("id") and has("concern_ref") and has("summary") and has("metric"))' "$REG" >/dev/null \
    && ok "every entry has id/concern_ref/summary/metric" || bad "entry missing a required key"
  DUP=$(jq -r '[.[].id] | (length - (unique | length))' "$REG")
  [ "$DUP" = "0" ] && ok "ids unique" || bad "duplicate ids in registry"
else
  echo "  (no live registry at ${REG:-<unset>} — structure checks skipped)"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# LOGBOOK_DATA_DIR is the official env override: config.sh derives STATE_DIR/
# REVIEWED_DIR from it in every child process, so the watch-report invocations
# below are hermetic without per-var overrides.
export LOGBOOK_DATA_DIR="$TMP"
export WM_LOG_DIR="$TMP/logs"
mkdir -p "$TMP/.state" "$TMP/reviewed" "$WM_LOG_DIR"

source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/lib/sessions-db.sh"; DB_PATH="$STATE_DIR/sessions.db"; init_sessions_db >/dev/null
db_insert_session z1 proj 2026-06-22 main
sqlite3 "$DB_PATH" "UPDATE sessions SET status='done', narrative_confidence='low', turns=5, tool_calls=2 WHERE session_id='z1';"
echo "# 2026-06-22" > "$REVIEWED_DIR/2026-06-22.md"

cat > "$TMP/reg.json" <<'JSON'
[
  {"id":"narr","concern_ref":"ref A","metric":"narrative_low_on_substantive","params":{},"windows":2,"summary":"low narratives","needs_judgment":"is each low real?"},
  {"id":"trace","concern_ref":"ref C","metric":"outcome_pattern_count","params":{"outcomes":["wrong_approach"],"trigger_count":2},"windows":2,"summary":"trace fixes","needs_judgment":"staged before trace?"},
  {"id":"gap","concern_ref":"ref B","metric":null,"summary":"no metric yet"}
]
JSON
OUT="$(WATCH_ITEMS_FILE="$TMP/reg.json" bash "$SCRIPT_DIR/watch-report.sh")"
echo "$OUT" | grep -q "low narratives" && ok "renders computed item label" || bad "missing computed label"
echo "$OUT" | grep -q "your call" && ok "renders needs_judgment marker" || bad "missing your-call marker"
echo "$OUT" | grep -q "not yet measured" && ok "renders null-metric gap" || bad "missing gap line"
echo "$OUT" | grep -Eqi "CLOSE|REOPEN|evidence supports" && bad "LEAKED a verdict string" || ok "no verdict string in output"

cat > "$TMP/bad.json" <<'JSON'
[{"id":"x","concern_ref":"r","metric":"does_not_exist","params":{},"summary":"s"}]
JSON
if WATCH_ITEMS_FILE="$TMP/bad.json" bash "$SCRIPT_DIR/watch-report.sh" >/dev/null 2>"$TMP/err"; then
  bad "bad metric name should abort"
else
  grep -q "does_not_exist" "$TMP/err" && ok "abort message names the bad metric" || bad "abort message unhelpful"
fi

cat > "$TMP/dup.json" <<'JSON'
[{"id":"d","concern_ref":"r","metric":null,"summary":"s"},{"id":"d","concern_ref":"r","metric":null,"summary":"s"}]
JSON
WATCH_ITEMS_FILE="$TMP/dup.json" bash "$SCRIPT_DIR/watch-report.sh" >/dev/null 2>&1 && bad "duplicate id should abort" || ok "duplicate id aborts"
WATCH_ITEMS_FILE="$TMP/dup.json" bash "$SCRIPT_DIR/watch-report.sh" >/dev/null 2>"$TMP/derr" || true
grep -q "duplicate id 'd'" "$TMP/derr" && ok "duplicate-id abort names the id" || bad "duplicate-id message does not name the id"

cat > "$TMP/missing.json" <<'JSON'
[{"concern_ref":"r","metric":null,"summary":"s"}]
JSON
WATCH_ITEMS_FILE="$TMP/missing.json" bash "$SCRIPT_DIR/watch-report.sh" >/dev/null 2>&1 && bad "missing required field should abort" || ok "missing required field aborts"

cat > "$TMP/unavail.json" <<'JSON'
[{"id":"u","concern_ref":"r","metric":"disarmed_block_count","params":{"log_file":"nope.log"},"windows":2,"summary":"block clears"}]
JSON
UOUT="$(WATCH_ITEMS_FILE="$TMP/unavail.json" bash "$SCRIPT_DIR/watch-report.sh")"
echo "$UOUT" | grep -q "metric source unreadable" && ok "unavailable renders source-unreadable marker" || bad "unavailable path missing marker"

ROUT="$(WATCH_ITEMS_FILE="$TMP/reg.json" bash "$SCRIPT_DIR/watch-report.sh" --report)"
[ "$ROUT" != "$OUT" ] && ok "--report differs from TUI" || bad "--report should differ from TUI now"
echo "$ROUT" | grep -q $'\033' && bad "--report leaked colour codes" || ok "--report is colour-free"
echo "$ROUT" | grep -q "rows (spot-check candidates):" && ok "--report renders rows section" || bad "--report missing rows section"
echo "$ROUT" | grep -Eqi "CLOSE|REOPEN|evidence supports" && bad "--report LEAKED a verdict" || ok "--report has no verdict string"

pos(){ echo "$OUT" | grep -n "$1" | head -1 | cut -d: -f1; }
[ "$(pos 'low narratives')" -lt "$(pos 'trace fixes')" ] && ok "orange sorts before green" || bad "orange not before green"
[ "$(pos 'trace fixes')" -lt "$(pos 'not yet measured')" ] && ok "green sorts before grey" || bad "green not before grey"

echo "$OUT" | grep -q $'\033\[38;5;214m' && ok "orange code present" || bad "orange code missing"
echo "$OUT" | grep -q $'\033\[38;5;82m'  && ok "green code present"  || bad "green code missing"

GREENYC="$(echo "$OUT" | grep -A1 'trace fixes' | grep 'your call')"
echo "$GREENYC" | grep -q $'\033\[38;5;245m' && ok "green your-call dimmed grey" || bad "green your-call not dimmed"

NCOUT="$(NO_COLOR=1 WATCH_ITEMS_FILE="$TMP/reg.json" bash "$SCRIPT_DIR/watch-report.sh")"
echo "$NCOUT" | grep -q $'\033' && bad "NO_COLOR left escape codes" || ok "NO_COLOR strips escape codes"

echo "watch-report: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
