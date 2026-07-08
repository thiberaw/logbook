#!/usr/bin/env bash
# =============================================================================
# test-watch-metrics.sh — unit tests for lib/watch-metrics.sh
#
# Builds a throwaway SQLite DB + a stub reviewed/ dir + a stub ~/.claude/logs
# audit log, then asserts wm_windows and each metric function against known
# inputs. Pure/deterministic — no network, no LLM, no real ~/.claude reads.
# Runs in the default sweep: for t in scripts/tests/*.sh; do bash "$t"; done
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- isolated fixtures: override the paths the libs read BEFORE sourcing them ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export STATE_DIR="$TMP/state"          # sessions-db.sh derives DB_PATH from this
export REVIEWED_DIR="$TMP/reviewed"
export WM_LOG_DIR="$TMP/logs"
mkdir -p "$STATE_DIR" "$REVIEWED_DIR" "$WM_LOG_DIR"

# config.sh sets STATE_DIR/REVIEWED_DIR from DATA_DIR; we must re-point them
# AFTER sourcing, because config.sh would overwrite our exports.
source "$SCRIPT_DIR/config.sh"
STATE_DIR="$TMP/state"; REVIEWED_DIR="$TMP/reviewed"
source "$SCRIPT_DIR/lib/sessions-db.sh"
DB_PATH="$STATE_DIR/sessions.db"        # re-point after sources
source "$SCRIPT_DIR/lib/watch-metrics.sh"

init_sessions_db >/dev/null

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || { bad "$3 (got [$1] want [$2])"; }; }

# --- seed sessions across 4 dates ---
# helper: insert a finished session with given fields
seed(){ # id date flagged heuristic outcome files narconf turns
  db_insert_session "$1" "proj" "$2" "main"
  sqlite3 "$DB_PATH" "UPDATE sessions SET status='done', flagged=$3, heuristic_flagged=$4, outcome='$5', files_modified=$6, narrative_confidence='$7', turns=$8, tool_calls=1 WHERE session_id='$1';"
}
seed s1 2026-06-20 0 0 success      0 high  10
seed s2 2026-06-22 1 1 success      0 high  10   # confirmed flag
seed s3 2026-06-22 0 1 success      0 high  10   # fired, cleared
seed s4 2026-06-23 0 0 wrong_approach 3 low   12   # wrong_approach + 3 files + low narrative
seed s5 2026-06-24 0 0 success      0 high  10   # has sessions but NO reviewed/ file

# reviewed/ files for 3 of the 4 dates (NOT 2026-06-24)
for d in 2026-06-20 2026-06-22 2026-06-23; do echo "# $d" > "$REVIEWED_DIR/$d.md"; done

# === wm_windows ===
W="$(wm_windows 2)"
assert_eq "$W" "$(printf '2026-06-23\n2026-06-22')" "wm_windows 2 = two most recent reviewed session-days, newest first"
assert_eq "$(wm_windows 2 | grep -c 2026-06-24)" "0" "wm_windows excludes session-day with no reviewed/ file"

# === wm_confirmed_flag_rate ===
R="$(wm_confirmed_flag_rate 2 '{"band_low":0.10,"band_high":0.40}')"
assert_eq "$(echo "$R" | jq -r .status)" "ok" "confirmed_flag_rate status ok"
# 2026-06-23: 0 fires -> "0/0"; 2026-06-22: 2 fires (s2 confirmed, s3 cleared) = 1/2 = 50% (out of band)
assert_eq "$(echo "$R" | jq -r .computed)" "2026-06-23 0/0 · 2026-06-22 1/2 (50%)" "confirmed_flag_rate computed string"
assert_eq "$(echo "$R" | jq -r .mechanical)" "0/1 windows in band · target 10-40%" "confirmed_flag_rate band count + target (only 06-22 had fires, 50% out of band)"
assert_eq "$(echo "$R" | jq -r .in_target)" "false" "confirmed_flag_rate in_target false (not every window in band)"
assert_eq "$(echo "$R" | jq -r '.rows[0]')" "[proj] (in progress)" "confirmed_flag_rate lists the confirmed-flagged session"

# === wm_disarmed_block_count ===
# (a) missing log -> unavailable, not 0
D_MISSING="$(wm_disarmed_block_count 2 '{"log_file":"nope.log"}')"
assert_eq "$(echo "$D_MISSING" | jq -r .status)" "unavailable" "disarmed: missing log -> unavailable"

# (b) present log, real format, fires inside the window window
cat > "$WM_LOG_DIR/scope-expansion-reset.log" <<'LOG'
2026-06-19T10:00:00 session=aaa count=5 warned=clear
2026-06-22T10:00:00 session=bbb count=40 warned=DISARMED-BLOCK
2026-06-23T11:00:00 session=ccc count=9 warned=clear
2026-06-23T12:00:00 session=ddd count=50 warned=DISARMED-BLOCK
LOG
D_OK="$(wm_disarmed_block_count 2 '{}')"   # windows = 06-23, 06-22 -> earliest 06-22
assert_eq "$(echo "$D_OK" | jq -r .status)" "ok" "disarmed: present log -> ok"
assert_eq "$(echo "$D_OK" | jq -r '.rows | length')" "2" "disarmed: counts both DISARMED-BLOCK lines on/after 06-22"

# (b2) present, valid format, zero DISARMED-BLOCK in window -> genuine ok/0 (NOT unavailable)
cat > "$WM_LOG_DIR/scope-expansion-reset.log" <<'LOG'
2026-06-22T10:00:00 session=eee count=5 warned=clear
2026-06-23T10:00:00 session=fff count=6 warned=clear
LOG
D_ZERO="$(wm_disarmed_block_count 2 '{}')"
assert_eq "$(echo "$D_ZERO" | jq -r .status)" "ok" "disarmed: valid format + 0 DISARMED-BLOCK -> ok (genuine zero, not unavailable)"
assert_eq "$(echo "$D_ZERO" | jq -r '.rows | length')" "0" "disarmed: genuine zero has no rows"
assert_eq "$(echo "$D_MISSING" | jq -r .in_target)" "null" "disarmed: unavailable -> in_target null"
assert_eq "$(echo "$D_OK" | jq -r .in_target)" "false" "disarmed: 2 fires -> in_target false"
assert_eq "$(echo "$D_ZERO" | jq -r .in_target)" "true" "disarmed: 0 fires -> in_target true"

# (c) present but format unrecognized -> unavailable
echo "garbage line no date" > "$WM_LOG_DIR/scope-expansion-reset.log"
D_BAD="$(wm_disarmed_block_count 2 '{}')"
assert_eq "$(echo "$D_BAD" | jq -r .status)" "unavailable" "disarmed: broken format -> unavailable (not 0)"

# === wm_outcome_pattern_count ===  (s4 on 06-23: wrong_approach, 3 files)
O="$(wm_outcome_pattern_count 2 '{"outcomes":["wrong_approach"],"files_modified_min":2,"trigger_count":2}')"
assert_eq "$(echo "$O" | jq -r .status)" "ok" "outcome_pattern status ok"
assert_eq "$(echo "$O" | jq -r '.rows | length')" "1" "outcome_pattern counts the wrong_approach+files session"
assert_eq "$(echo "$O" | jq -r .mechanical)" "below trigger count (1 of 2)" "outcome_pattern below trigger"
assert_eq "$(echo "$O" | jq -r .in_target)" "true" "outcome_pattern in_target true (1 < trigger 2)"

# === wm_narrative_low_on_substantive ===  (s4 is low + substantive)
N="$(wm_narrative_low_on_substantive 2 '{}')"
assert_eq "$(echo "$N" | jq -r '.rows | length')" "1" "narrative_low counts the substantive low-confidence session"
assert_eq "$(echo "$N" | jq -r .in_target)" "false" "narrative_low in_target false (1 substantive low)"

# === wm_meta_cost_ratio ===
# Give the two existing reviewed windows cost + meta_cost. Other metric tests read
# only flag/outcome/narrative fields, so setting cost/meta_cost here is inert to them.
#   06-22: meta 0.10 / total 10.10 ≈ 1%  (in band, ≤ 3% ceiling)
#   06-23: meta 0.50 / total 1.50  ≈ 33% (over ceiling)
sqlite3 "$DB_PATH" "UPDATE sessions SET cost=5, meta_cost=0.05 WHERE session_id IN ('s2','s3');"
sqlite3 "$DB_PATH" "UPDATE sessions SET cost=1, meta_cost=0.5 WHERE session_id='s4';"
MC="$(wm_meta_cost_ratio 2 '{"ceiling":0.03}')"
assert_eq "$(echo "$MC" | jq -r .status)" "ok" "meta_cost_ratio status ok"
assert_eq "$(echo "$MC" | jq -r .computed)" "2026-06-23 \$0.5/\$1.50 (33.3%) · 2026-06-22 \$0.1/\$10.10 (1.0%)" "meta_cost_ratio per-window ratios (dot decimals under any locale)"
assert_eq "$(echo "$MC" | jq -r .in_target)" "false" "meta_cost_ratio in_target false (06-23 over the 3% ceiling)"
assert_eq "$(echo "$MC" | jq -r .mechanical)" "1/2 windows ≤ 3% overhead" "meta_cost_ratio band count vs ceiling"
assert_eq "$(echo "$MC" | jq -r '.rows | length')" "3" "meta_cost_ratio lists highest-meta_cost rows across measured windows"

# a window whose sessions all predate instrumentation (meta_cost=0) -> unavailable,
# NEVER a false '0% overhead' (s1 on 06-20 has meta_cost 0).
mkdir -p "$TMP/meta_reviewed"; echo "# 2026-06-20" > "$TMP/meta_reviewed/2026-06-20.md"
MC_UNAVAIL="$( REVIEWED_DIR="$TMP/meta_reviewed"; wm_meta_cost_ratio 2 '{"ceiling":0.03}' )"
assert_eq "$(echo "$MC_UNAVAIL" | jq -r .status)" "unavailable" "meta_cost_ratio: no meta_cost in window -> unavailable (not false 0%)"
assert_eq "$(echo "$MC_UNAVAIL" | jq -r .in_target)" "null" "meta_cost_ratio: unavailable -> in_target null"

# === wm_confirmed_flag_rate_split (intervention before/after) ===
# split at 06-23: before = 06-20+06-22 fires (s2,s3 = 2 fires, s2 confirmed = 1);
# after = 06-23 (0 fires). Proves the before/after aggregation the ledger renders.
SP="$(wm_confirmed_flag_rate_split 2026-06-23)"
assert_eq "$SP" "before 1/2 (50%) · after 0/0 (n/a)" "confirmed_flag_rate_split before/after around a date"

# no-windows -> in_target null (subshell isolates the REVIEWED_DIR override)
mkdir -p "$TMP/empty_reviewed"
NULLCASE="$( REVIEWED_DIR="$TMP/empty_reviewed"; wm_narrative_low_on_substantive 2 '{}' )"
assert_eq "$(echo "$NULLCASE" | jq -r .in_target)" "null" "no-windows -> in_target null"

echo "watch-metrics: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
