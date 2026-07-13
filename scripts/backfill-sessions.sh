#!/usr/bin/env bash
# =============================================================================
# backfill-sessions.sh — re-process sessions that recorded 0 turns  [UTILITY]
#
# WHAT IT IS : a manual repair tool. Some sessions end up with a DB row but no
#              metrics (turns = 0), usually because the background worker
#              crashed. This re-finds each transcript and re-runs the worker.
# ITS JOB    : turn "empty" session rows back into fully-analyzed rows.
# INPUT      : none (no args/stdin) — it reads the SQLite DB for empty rows.
# IT CALLS   : sqlite3, find, and session-end-worker.sh (the real analyzer).
#
# HOW TO READ THIS FILE — runs top to bottom, in these sections:
#   [setup]        strict mode, locate self, load shared libs, open the DB
#   [find-empty]   query the DB for sessions with 0 turns
#   [backfill]     loop each session: find its transcript, re-run the worker
#   [summary]      print how many were processed vs skipped
# =============================================================================

# --- [setup] -----------------------------------------------------------------
# Strict mode. -u: using an unset variable is an error; -o pipefail: a pipeline
# fails if ANY stage fails (not just the last). Note: NO -e here, so the loop
# below keeps going even if one session's worker call fails.
set -uo pipefail

# Absolute path to this script's own directory (so sourcing works from anywhere).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# config.sh defines DB_PATH, CLAUDE_PROJECTS_DIR, … ; sessions-db.sh defines init_sessions_db.
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/sessions-db.sh"

# Create the DB/schema if it doesn't exist yet.
init_sessions_db

# --- [find-empty] ------------------------------------------------------------
# Find empty sessions (have a row but no metrics). The SQL selects finished
# sessions recorded as 0 turns in the last 30 days — older transcripts no
# longer exist to re-analyze — oldest first.
EMPTY_SESSIONS=$(sqlite3 "$DB_PATH" "
  SELECT session_id FROM sessions
  WHERE turns = 0 AND status = 'done' AND date >= date('now', '-30 days')
  ORDER BY created_at;
")

# `[ -z ... ]` is true when the string is empty: nothing to do, so exit cleanly.
if [ -z "$EMPTY_SESSIONS" ]; then
  echo "No empty sessions to backfill."
  exit 0
fi

# Count the rows: `wc -l` counts newlines in the query result.
COUNT=$(echo "$EMPTY_SESSIONS" | wc -l)
echo "Found $COUNT empty sessions to backfill."

# --- [backfill] --------------------------------------------------------------
# Running tallies for the final summary line.
PROCESSED=0
SKIPPED=0

# Loop over each session id. `IFS= read -r` reads one whole line at a time
# without trimming whitespace or mangling backslashes. The `<<< "$EMPTY_SESSIONS"`
# at the bottom is a "here-string": it feeds the query result into the loop's stdin.
while IFS= read -r SESSION_ID; do
  # Skip blank lines (e.g. a trailing newline in the query output).
  [ -z "$SESSION_ID" ] && continue

  # Find the transcript file for this session across all project dirs.
  # Claude stores transcripts as <session-id>.jsonl directly in the project dir.
  TRANSCRIPT=""
  # `find ... -maxdepth 2 -name "<id>.jsonl" -print -quit`: search up to two
  # directory levels deep, print the FIRST match, then `-quit` stops searching.
  TRANSCRIPT=$(find "$CLAUDE_PROJECTS_DIR" -maxdepth 2 -name "${SESSION_ID}.jsonl" -print -quit 2>/dev/null)

  # If nothing was found (empty string) or the path isn't a real file, skip it.
  if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
    echo "  SKIP $SESSION_ID — no transcript found"
    # $(( )) is integer arithmetic.
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Derive the working directory (CWD) from the project-dir name. Claude encodes
  # a project's absolute path by replacing every "/" with "-", e.g.
  #   ~/.claude/projects/-home-you-projects-my-app-services-api/
  #     → /home/you/projects/my-app/services/api
  # `dirname` gets the project dir, `basename` strips the leading path.
  PROJECT_ENCODED=$(basename "$(dirname "$TRANSCRIPT")")
  # Reverse the encoding: 1st sed turns every "-" back into "/"; 2nd sed strips
  # the now-leading "/" (the encoded name began with a "-"); then we re-add a
  # single leading "/" to form a clean absolute path.
  CWD=$(echo "$PROJECT_ENCODED" | sed 's/-/\//g' | sed 's|^/||')
  CWD="/$CWD"

  echo "  BACKFILL $SESSION_ID → $PROJECT_ENCODED"

  # Reset status so the worker is allowed to update this row again.
  sqlite3 "$DB_PATH" "UPDATE sessions SET status = 'in_progress' WHERE session_id = '$SESSION_ID';"

  # Run the worker synchronously (not backgrounded) so we process one at a time.
  # LOGBOOK_ANALYZER=1 is an env flag the worker checks. `2>&1` merges the
  # worker's stderr into stdout, and `sed 's/^/    /'` indents every output line
  # by 4 spaces so it reads as nested under the BACKFILL line above.
  LOGBOOK_ANALYZER=1 bash "$SCRIPT_DIR/session-end-worker.sh" "$SESSION_ID" "$TRANSCRIPT" "$CWD" 2>&1 | sed 's/^/    /'

  PROCESSED=$((PROCESSED + 1))
done <<< "$EMPTY_SESSIONS"

# --- [summary] ---------------------------------------------------------------
echo ""
echo "Done: $PROCESSED processed, $SKIPPED skipped (no transcript)."
