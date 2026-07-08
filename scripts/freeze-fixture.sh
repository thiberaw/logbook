#!/usr/bin/env bash
# =============================================================================
# freeze-fixture.sh — turn a session into a flag-corpus fixture  [UTILITY]
#
# WHAT IT IS: the corpus-growth path for the flag-analysis eval harness. Given a
#   session id, it regenerates that session's condensed transcript into the
#   PRIVATE eval corpus at $FIXTURES_DIR (using the SAME condense + head/tail
#   elision the worker feeds the model) and prints a manifest row to paste into
#   flag-corpus.tsv. The corpus is user data — it never lives in the tool tree.
# IT DOES NOT auto-append: YOU set `expected` (confirm|clear) and verify
#   `flag_reasons`, because a mislabeled fixture corrupts the gate.
# USAGE: scripts/freeze-fixture.sh <session_id> [slug]
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/lib/sessions-db.sh"

SID="${1:?usage: freeze-fixture.sh <session_id> [slug]}"
SLUG="${2:-${SID:0:8}}"

TRANSCRIPT=$(find "$CLAUDE_PROJECTS_DIR" -maxdepth 2 -name "${SID}.jsonl" -print -quit 2>/dev/null)
if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  echo "ERROR: no transcript found for $SID (aged out of the 12-day window?)" >&2
  exit 1
fi

CONDENSED=$(python3 "$SCRIPT_DIR/lib/transcript-analyzer.py" --condensed "$TRANSCRIPT" 2>/dev/null || echo "")
if [ -z "$CONDENSED" ]; then
  echo "ERROR: transcript-analyzer produced no condensed output for $SID" >&2
  exit 1
fi
# Same head+tail elision the worker applies before feeding the model (>15000 chars).
if [ ${#CONDENSED} -gt 15000 ]; then
  ELIDED=$(( ${#CONDENSED} - 15000 ))
  CONDENSED="${CONDENSED:0:9000}
[... ${ELIDED} chars of mid-session trace elided (sampled head+tail) ...]
${CONDENSED: -6000}"
fi

mkdir -p "$FIXTURES_DIR"
OUT="$FIXTURES_DIR/${SLUG}.condensed.txt"
printf '%s\n' "$CONDENSED" > "$OUT"

# Pull the frozen metrics from the DB (tab-separated to survive any spaces).
IFS=$'\t' read -r project branch dur cost turns calls errs files < <(
  sqlite3 -separator $'\t' "$DB_PATH" \
    "SELECT project, branch, duration, cost, turns, tool_calls, tool_errors, files_modified
     FROM sessions WHERE session_id='$SID';")

echo "wrote $OUT" >&2
echo "# paste into $FIXTURES_DIR/flag-corpus.tsv, then set <SET:...> fields:" >&2
printf '%s\t<SET:confirm|clear>\t<SET-flag-reason>\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "${SLUG}.condensed.txt" "$project" "$branch" "$dur" "$cost" "$turns" "$calls" "$errs" "$files"
