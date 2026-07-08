#!/usr/bin/env bash
# =============================================================================
# hook-report.sh — read-only hook-health evidence from the 2a telemetry log.
#
# WHAT IT IS:  per-hook fire counts, sub-classes, recent-fire spot-check rows,
#              and the inert-hook roster, computed from hook-fires.log + the
#              scope-expansion reset log. EVIDENCE, NEVER A VERDICT — prune/keep
#              calls stay with the human. Consumed by /improve step 5 alongside
#              watch-report.sh; deliberately NOT surfaced in morning-review.
# GROUPING:    strictly by hook=, never tool= (bash-burst-warning logs
#              tool=Bash even when a Read tipped the burst — the 2a caveat).
# DEGRADATION: no/empty fires log → "no telemetry yet", exit 0. Missing reset
#              log → disarm line omitted. Malformed lines skipped and counted.
# OVERRIDES:   HOOK_FIRES_LOG, SCOPE_RESET_LOG, HOOKS_DIR, HOOK_REPORT_DB
#              (for the hermetic test).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

FIRES_LOG="${HOOK_FIRES_LOG:-$HOME/.claude/logs/hook-fires.log}"
RESET_LOG="${SCOPE_RESET_LOG:-$HOME/.claude/logs/scope-expansion-reset.log}"
HOOKS_DIR="${HOOKS_DIR:-$HOME/.claude/hooks}"
DB="${HOOK_REPORT_DB:-$STATE_DIR/sessions.db}"

if [ ! -s "$FIRES_LOG" ]; then
  echo "HOOK HEALTH — no telemetry yet ($FIRES_LOG missing or empty)"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- normalize valid lines to TSV: ts \t hook \t session \t detail -----------
sed -nE 's/^([0-9]{4}-[0-9]{2}-[0-9]{2}T[^ ]+) hook=([^ ]+) session=([^ ]+) [^"]*detail="(.*)"$/\1\t\2\t\3\t\4/p' \
  "$FIRES_LOG" > "$TMP/fires.tsv"
TOTAL=$(wc -l < "$TMP/fires.tsv")
MALFORMED=$(( $(wc -l < "$FIRES_LOG") - TOTAL ))
if [ "$TOTAL" -eq 0 ]; then
  echo "HOOK HEALTH — no telemetry yet (no parseable lines in $FIRES_LOG)"
  exit 0
fi

# --- rosters ------------------------------------------------------------------
grep -l hook_log_fire "$HOOKS_DIR"/*.sh 2>/dev/null \
  | xargs -rn1 basename | sed 's/\.sh$//' | sort > "$TMP/instrumented" || true
cut -f2 "$TMP/fires.tsv" | sort | uniq -c | sort -rn > "$TMP/fired"
awk '{print $2}' "$TMP/fired" | sort > "$TMP/fired.names"
FIRED_N=$(wc -l < "$TMP/fired")
INSTR_N=$(wc -l < "$TMP/instrumented")
TOP_N=$(awk 'NR==1{print $1}' "$TMP/fired")
TOP_HOOK=$(awk 'NR==1{print $2}' "$TMP/fired")
SKEW=$(( TOP_N * 100 / TOTAL ))

# --- optional sessions.db map: session \t project \t skill \t flagged ---------
# Degrades to log-only output when sqlite3 or the DB is missing; fire sessions
# absent from the DB (pruned rows, other machines) count as "unmatched".
DB_OK=0
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DB" ]; then
  # Only well-formed IDs reach the SQL string — a corrupted log line with a
  # quote in session= would otherwise break the query and misreport the DB
  # as unavailable. Filtered-out IDs simply count as unmatched.
  IDS=$(cut -f3 "$TMP/fires.tsv" | sort -u | grep -E '^[0-9a-fA-F-]+$' \
    | sed "s/.*/'&'/" | paste -sd, - || true)
  if [ -n "$IDS" ] && sqlite3 -separator "$(printf '\t')" "$DB" \
       "SELECT session_id, project, COALESCE(NULLIF(skill,''),'-'), flagged FROM sessions WHERE session_id IN ($IDS);" \
       > "$TMP/map.tsv" 2>/dev/null; then
    DB_OK=1
  fi
fi
: > "$TMP/map.ids"
if [ "$DB_OK" -eq 1 ]; then
  cut -f1 "$TMP/map.tsv" | sort -u > "$TMP/map.ids"
fi

# --- header -------------------------------------------------------------------
echo "HOOK HEALTH — computed evidence as of $(date +%Y-%m-%d)"
echo "$TOTAL fires · $FIRED_N of $INSTR_N instrumented hooks · skew: ${SKEW}% $TOP_HOOK"
echo "(small-N warning: hooks under ~10 fires are anecdotal, not statistical)"
if [ "$MALFORMED" -gt 0 ]; then
  echo "($MALFORMED malformed lines skipped)"
fi
if [ "$DB_OK" -eq 0 ]; then
  echo "(sessions.db unavailable — log-only output)"
fi
echo ""

CUTOFF=$(date -d '7 days ago' +%Y-%m-%dT%H:%M:%S)

your_call() {
  case "$1" in
    read-size-guard)
      echo "  ⚠ your call: are the re-read blocks preventing waste, or fighting legitimate re-reads after context loss?" ;;
    bash-burst-warning)
      echo "  ⚠ your call: were the bursts genuine spirals, or normal parallel tool use?" ;;
    scope-expansion-block)
      echo "  ⚠ your call: did any block coincide with genuine autonomous expansion, or was it all authorized work?" ;;
    *)
      echo "  ⚠ your call: spot-check the recent fires: friction or protection?" ;;
  esac
}

# --- per-hook blocks (fire-count order) ----------------------------------------
while read -r COUNT HOOK; do
  awk -F'\t' -v h="$HOOK" '$2==h' "$TMP/fires.tsv" > "$TMP/hook.tsv"
  RECENT=$(awk -F'\t' -v c="$CUTOFF" '$1>=c' "$TMP/hook.tsv" | wc -l)
  SESS=$(cut -f3 "$TMP/hook.tsv" | sort -u | wc -l)
  LINE="$HOOK  $COUNT fires ($RECENT last 7d) · $SESS sessions"
  if [ "$DB_OK" -eq 1 ]; then
    FLAGGED=$(awk -F'\t' 'FILENAME==ARGV[1] { if ($4==1) f[$1]=1; next }
      ($3 in f) && !seen[$3]++ { c++ } END { print c+0 }' \
      "$TMP/map.tsv" "$TMP/hook.tsv")
    UNMATCHED=$(comm -23 <(cut -f3 "$TMP/hook.tsv" | sort -u) "$TMP/map.ids" | wc -l)
    LINE="$LINE · $FLAGGED flagged · $UNMATCHED unmatched"
  fi
  echo "$LINE"
  if [ "$HOOK" = "read-size-guard" ]; then
    REREAD=$(cut -f4 "$TMP/hook.tsv" | grep -c '^re-read' || true)
    OVERSIZE=$(cut -f4 "$TMP/hook.tsv" | grep -c '^oversize' || true)
    echo "  sub-classes: re-read $REREAD · oversize $OVERSIZE"
  fi
  if [ "$DB_OK" -eq 1 ]; then
    CLUSTERS=$(awk -F'\t' 'FILENAME==ARGV[1] { m[$1]=$2 "/" $3; next }
      { print (($3 in m) ? m[$3] : "unmatched") }' \
      "$TMP/map.tsv" "$TMP/hook.tsv" \
      | sort | uniq -c | sort -rn | head -3 \
      | awk '{ printf "%s%s %d", sep, $2, $1; sep=" · " } END { print "" }')
    echo "  clusters: $CLUSTERS"
  fi
  echo "  recent fires (spot-check candidates):"
  tail -3 "$TMP/hook.tsv" | awk -F'\t' '{
    d = substr($1, 1, 10); s = substr($3, 1, 8); t = $4
    if (length(t) > 60) t = substr(t, 1, 60) "…"
    printf "    - %s session=%s… \"%s\"\n", d, s, t
  }'
  if [ "$HOOK" = "scope-expansion-block" ] && [ -s "$RESET_LOG" ]; then
    # Only DISARMED-BLOCK is a disarm event. warned=clear lines fire on EVERY
    # user prompt (the UserPromptSubmit rebase), so counting them would print
    # a lifetime prompt counter and invite a meaningless ratio.
    DISARMS=$(grep -c 'warned=DISARMED-BLOCK$' "$RESET_LOG" || true)
    if [ "$DISARMS" -gt 0 ]; then
      FIRST_D=$(grep 'warned=DISARMED-BLOCK$' "$RESET_LOG" | head -1 | cut -c1-10)
      LAST_D=$(grep 'warned=DISARMED-BLOCK$' "$RESET_LOG" | tail -1 | cut -c1-10)
      echo "  disarm log: $DISARMS DISARMED-BLOCK all-time (first $FIRST_D · last $LAST_D)"
    fi
  fi
  your_call "$HOOK"
  echo ""
done < "$TMP/fired"

# --- inert roster ----------------------------------------------------------------
INERT=$(comm -23 "$TMP/instrumented" "$TMP/fired.names" | paste -sd, - | sed 's/,/, /g')
if [ -n "$INERT" ]; then
  echo "INERT (instrumented, zero fires ever):"
  echo "  $INERT"
  echo "  ⚠ your call: deterrent or dead weight — check each hook's last genuine catch in hooks-changelog.md before pruning."
fi

exit 0
