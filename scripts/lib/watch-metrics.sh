#!/usr/bin/env bash
# =============================================================================
# watch-metrics.sh — computable metrics for the intervention efficacy tracker
#                                                   [LIBRARY — sourced, not run]
#
# WHAT IT IS:  one pure-read function per registered watch-item metric, plus the
#              shared window resolver every metric flows through (so the reporter
#              and the metrics never disagree on what "last N windows" means).
# SOURCED BY:  scripts/watch-report.sh, scripts/tests/test-watch-metrics.sh.
#              Source config.sh + lib/sessions-db.sh first (needs $DB_PATH,
#              $REVIEWED_DIR).
# CONTRACT:    each wm_<metric> prints ONE json line: {status,in_target,computed,mechanical,rows}.
#              status is "ok" or "unavailable" (source missing/format broken — never
#              a false 0). in_target is true|false|null — a MECHANICAL in/out-of-target
#              flag for colour/sort, never a close/reopen verdict. The reporter renders it.
# =============================================================================

# Hook audit logs live outside this repo; overridable so tests use a stub dir.
WM_LOG_DIR="${WM_LOG_DIR:-$HOME/.claude/logs}"

# wm_windows N — the N most-recent windows, newest first. A window is a date that
# has at least one session AND a reviewed/<date>.md file (an unreviewed day is not
# final evidence). Prints nothing when there are none.
wm_windows() {
  local n="${1:-2}" out=() count=0 d
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    if [ -f "$REVIEWED_DIR/$d.md" ]; then
      out+=("$d"); count=$((count + 1))
      [ "$count" -ge "$n" ] && break
    fi
  done < <(sqlite3 "$DB_PATH" "SELECT DISTINCT date FROM sessions ORDER BY date DESC;")
  [ "${#out[@]}" -gt 0 ] && printf '%s\n' "${out[@]}"
}

# _wm_emit STATUS IN_TARGET COMPUTED MECHANICAL ROWS_NL — build the result JSON.
# IN_TARGET is the string true|false|null (a mechanical in/out-of-target flag,
# NOT a verdict). ROWS_NL is newline-separated; blank lines are dropped.
_wm_emit() {
  local status="$1" in_target="$2" computed="$3" mechanical="$4" rows_nl="$5" rows_json="[]"
  if [ -n "$rows_nl" ]; then
    rows_json=$(printf '%s\n' "$rows_nl" | grep -v '^[[:space:]]*$' | jq -R . | jq -s .)
  fi
  jq -n --arg s "$status" --argjson it "$in_target" --arg c "$computed" --arg m "$mechanical" --argjson r "$rows_json" \
    '{status:$s, in_target:$it, computed:$c, mechanical:$m, rows:$r}'
}

# wm_confirmed_flag_rate WINDOWS PARAMS — heuristic flag FIRES vs LLM-CONFIRMED
# flags, per window. A confirm rate stuck at ~0% or >band means the flag prompt
# drifted, not that sessions changed. PARAMS: {band_low, band_high} as fractions.
wm_confirmed_flag_rate() {
  local windows="$1" params="$2"
  local low high; low=$(echo "$params" | jq -r '.band_low // 0.10')
  high=$(echo "$params" | jq -r '.band_high // 0.40')
  local dates; dates=$(wm_windows "$windows")
  [ -z "$dates" ] && { _wm_emit ok null "no windows yet" "0/0 windows in band" ""; return; }
  local computed="" inband=0 total=0 rows="" d fires confirms pct
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    fires=$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(heuristic_flagged),0) FROM sessions WHERE date='$d';")
    confirms=$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(CASE WHEN heuristic_flagged=1 THEN flagged ELSE 0 END),0) FROM sessions WHERE date='$d';")
    if [ "$fires" -gt 0 ]; then
      total=$((total + 1))
      # integer pct (display approximation; band edge cases round to nearest %)
      pct=$(( confirms * 100 / fires ))
      computed="${computed:+$computed · }$d $confirms/$fires (${pct}%)"
      if awk -v p="$pct" -v lo="$low" -v hi="$high" 'BEGIN{exit !(p/100>=lo && p/100<=hi)}'; then
        inband=$((inband + 1))
      fi
      # rows are the spot-check superset (any flagged session in the window), deliberately
      # broader than the confirms count above — surfacing more candidates can't hide a problem.
      rows="$rows$(sqlite3 "$DB_PATH" "SELECT name FROM sessions WHERE date='$d' AND flagged=1;")
"
    else
      computed="${computed:+$computed · }$d 0/0"
    fi
  done <<< "$dates"
  local lowpct highpct it
  lowpct=$(awk -v l="$low" 'BEGIN{printf "%g", l*100}')
  highpct=$(awk -v h="$high" 'BEGIN{printf "%g", h*100}')
  if [ "$total" -eq 0 ]; then it=null; elif [ "$inband" -eq "$total" ]; then it=true; else it=false; fi
  _wm_emit ok "$it" "$computed" "$inband/$total windows in band · target ${lowpct}-${highpct}%" "$rows"
}

# wm_meta_cost_ratio WINDOWS PARAMS — the pipeline's OWN spend (SUM meta_cost) as
# a fraction of TOTAL spend (user cost + meta_cost), per window. This is the
# reflection loop measuring its own overhead: the answer to "how much of the spend
# is signal vs ceremony?". PARAMS: {ceiling} (fraction, default 0.03) — in_target
# when the ratio stays at or below the ceiling.
# meta_cost is populated going forward from instrumentation only: a window whose sessions
# all predate instrumentation sums to 0 and is reported UNMEASURED — never a false
# "0% overhead" (the never-false-0 convention). All windows unmeasured -> unavailable.
wm_meta_cost_ratio() {
  local windows="$1" params="$2"
  local ceiling; ceiling=$(echo "$params" | jq -r '.ceiling // 0.03')
  local dates; dates=$(wm_windows "$windows")
  [ -z "$dates" ] && { _wm_emit ok null "no windows yet" "0/0 windows measured" ""; return; }
  local computed="" inband=0 total=0 rows="" d meta usr tot ratio pct
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    meta=$(sqlite3 "$DB_PATH" "SELECT ROUND(COALESCE(SUM(meta_cost),0),4) FROM sessions WHERE date='$d';")
    usr=$(sqlite3 "$DB_PATH" "SELECT ROUND(COALESCE(SUM(cost),0),2) FROM sessions WHERE date='$d';")
    # No meta_cost recorded -> the window predates instrumentation; unmeasurable.
    # LC_ALL=C on every awk forces a '.' decimal (a French locale would otherwise
    # print/parse '0,33', and awk reads '0,33' as 0 — silently breaking the compare).
    if LC_ALL=C awk -v m="$meta" 'BEGIN{exit !(m<=0)}'; then
      computed="${computed:+$computed · }$d unmeasured"
      continue
    fi
    total=$((total + 1))
    tot=$(LC_ALL=C awk -v m="$meta" -v u="$usr" 'BEGIN{printf "%.2f", m+u}')
    ratio=$(LC_ALL=C awk -v m="$meta" -v t="$tot" 'BEGIN{printf "%.4f", (t>0)?m/t:0}')
    pct=$(LC_ALL=C awk -v r="$ratio" 'BEGIN{printf "%.1f", r*100}')
    computed="${computed:+$computed · }$d \$${meta}/\$${tot} (${pct}%)"
    if LC_ALL=C awk -v r="$ratio" -v c="$ceiling" 'BEGIN{exit !(r<=c)}'; then
      inband=$((inband + 1))
    fi
    rows="$rows$(sqlite3 "$DB_PATH" "SELECT name || ' (meta \$' || ROUND(meta_cost,4) || ')' FROM sessions WHERE date='$d' AND meta_cost>0 ORDER BY meta_cost DESC LIMIT 3;")
"
  done <<< "$dates"
  if [ "$total" -eq 0 ]; then
    _wm_emit unavailable null "$computed" "no window has meta_cost yet (populated going forward only)" ""
    return
  fi
  local ceilpct it
  ceilpct=$(LC_ALL=C awk -v c="$ceiling" 'BEGIN{printf "%g", c*100}')
  if [ "$inband" -eq "$total" ]; then it=true; else it=false; fi
  _wm_emit ok "$it" "$computed" "$inband/$total windows ≤ ${ceilpct}% overhead" "$rows"
}

# wm_confirmed_flag_rate_split DATE — the confirmed-flag rate over all sessions
# BEFORE vs ON/AFTER a date. Powers the intervention before/after in watch-report:
# e.g. did a model bump (rather than the prompt tweaks before it) lift the rate
# off a flat baseline? Prints one line: "before <C/F (P%)> · after <C/F (P%)>". Only
# rows from after the heuristic_flagged column existed carry fires, so a split date before that
# has an empty before-side — which is itself honest about what's measurable.
wm_confirmed_flag_rate_split() {
  local date="$1" bf bc af ac bp="n/a" ap="n/a"
  bf=$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(heuristic_flagged),0) FROM sessions WHERE date<'$date';")
  bc=$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(CASE WHEN heuristic_flagged=1 THEN flagged ELSE 0 END),0) FROM sessions WHERE date<'$date';")
  af=$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(heuristic_flagged),0) FROM sessions WHERE date>='$date';")
  ac=$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(CASE WHEN heuristic_flagged=1 THEN flagged ELSE 0 END),0) FROM sessions WHERE date>='$date';")
  [ "$bf" -gt 0 ] && bp="$(( bc * 100 / bf ))%"
  [ "$af" -gt 0 ] && ap="$(( ac * 100 / af ))%"
  printf 'before %s/%s (%s) · after %s/%s (%s)' "$bc" "$bf" "$bp" "$ac" "$af" "$ap"
}

# wm_disarmed_block_count WINDOWS PARAMS — count of hook block-clear events
# (warned=<pattern> lines) in a hook audit log over the window. The log is
# machine-wide and its format is an UNVERSIONED external contract, so:
#   - missing file               -> unavailable (never 0)
#   - present but no dated line   -> unavailable (format changed; never a false 0)
#   - present, dated, 0 matches   -> ok, genuine 0
# Windowed by calendar date >= the earliest window date (lines carry an ISO ts).
wm_disarmed_block_count() {
  local windows="$1" params="$2"
  local logfile pattern path
  logfile=$(echo "$params" | jq -r '.log_file // "scope-expansion-reset.log"')
  pattern=$(echo "$params" | jq -r '.pattern // "DISARMED-BLOCK"')
  path="$WM_LOG_DIR/$logfile"
  if [ ! -f "$path" ]; then
    _wm_emit unavailable null "metric source unreadable: $logfile missing" "" ""; return
  fi
  if ! grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T.* warned=' "$path"; then
    _wm_emit unavailable null "metric source unreadable: $logfile format unrecognized" "" ""; return
  fi
  local dates; dates=$(wm_windows "$windows")
  [ -z "$dates" ] && { _wm_emit ok null "no windows yet" "0 fires" ""; return; }
  local earliest; earliest=$(echo "$dates" | sort | head -1)
  local rows count
  rows=$(awk -v start="$earliest" -v pat="warned=$pattern" '
    substr($0,1,10) >= start && index($0,pat) { print }' "$path")
  count=$(printf '%s\n' "$rows" | grep -c . || true)
  local mech; if [ "$count" -eq 0 ]; then mech="in band (0 fires)"; else mech="$count fires — review"; fi
  local it; if [ "$count" -eq 0 ]; then it=true; else it=false; fi
  _wm_emit ok "$it" "$pattern lines since $earliest: $count" "$mech" "$rows"
}

# _wm_date_in_list DATES_NL — turn a newline list of dates into a SQL IN clause
# body: 'd1','d2'  (empty -> "''" so the query is valid and matches nothing).
_wm_date_in_list() {
  local list; list=$(printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | sed "s/.*/'&'/" | paste -sd, -)
  echo "${list:-''}"
}

# wm_outcome_pattern_count WINDOWS PARAMS — sessions with a flagged outcome class
# (+ optional files_modified floor) over the windows, compared to a trigger count.
wm_outcome_pattern_count() {
  local windows="$1" params="$2"
  local trig; trig=$(echo "$params" | jq -r '(.trigger_count // 2) | floor')
  local dates; dates=$(wm_windows "$windows")
  [ -z "$dates" ] && { _wm_emit ok null "no windows yet" "below trigger count (0 of $trig)" ""; return; }
  local dlist; dlist=$(_wm_date_in_list "$dates")
  local olist; olist=$(echo "$params" | jq -r '(.outcomes // ["wrong_approach"]) | map("'"'"'" + . + "'"'"'") | join(",")')
  local fmin; fmin=$(echo "$params" | jq -r '(.files_modified_min // 0) | floor')
  local rows count
  rows=$(sqlite3 "$DB_PATH" "SELECT name FROM sessions WHERE date IN ($dlist) AND outcome IN ($olist) AND files_modified >= $fmin;")
  count=$(printf '%s\n' "$rows" | grep -c . || true)
  local mech; if [ "$count" -ge "$trig" ]; then mech="at/over trigger ($count of $trig)"; else mech="below trigger count ($count of $trig)"; fi
  local it; if [ "$count" -lt "$trig" ]; then it=true; else it=false; fi
  _wm_emit ok "$it" "matching sessions in window: $count" "$mech" "$rows"
}

# wm_narrative_low_on_substantive WINDOWS PARAMS — substantive sessions whose LLM
# narrative was cross-checked 'low' (contradicts the deterministic facts).
wm_narrative_low_on_substantive() {
  local windows="$1" params="$2"
  local dates; dates=$(wm_windows "$windows")
  [ -z "$dates" ] && { _wm_emit ok null "no windows yet" "0 substantive low-confidence narratives" ""; return; }
  local dlist; dlist=$(_wm_date_in_list "$dates")
  local rows count
  rows=$(sqlite3 "$DB_PATH" "SELECT name FROM sessions WHERE date IN ($dlist) AND narrative_confidence='low' AND (turns > 0 OR tool_calls > 0);")
  count=$(printf '%s\n' "$rows" | grep -c . || true)
  local it; if [ "$count" -eq 0 ]; then it=true; else it=false; fi
  _wm_emit ok "$it" "substantive low-confidence narratives: $count" "$count substantive low-confidence narratives" "$rows"
}
