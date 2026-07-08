#!/usr/bin/env bash
# =============================================================================
# session-start.sh — SessionStart hook: register a new Claude session  [ENTRY POINT]
#
# WHAT IT IS:  A Claude Code "SessionStart" hook. Claude Code runs it
#              automatically every time a new session begins.
# ITS JOB:     Record the new session in the SQLite database, prune old
#              bookkeeping files, and print a "system reminder" that tells
#              Claude how to keep the session row updated while it runs.
# INPUT:       A JSON object on stdin, e.g. { "session_id": "...", "cwd": "..." }.
# IT CALLS:    config.sh, lib/logging.sh, lib/sessions-db.sh (sourced helpers),
#              plus the `jq`, `sqlite3`, and `git` command-line tools.
#
# HOW TO READ THIS FILE — runs top to bottom, in these sections:
#   [setup]            strict mode, load helper libraries, define file paths
#   [read-input]       parse the JSON from stdin and decide whether to run
#   [state-bookkeeping] record the start time, prune old tracking entries
#   [prune-daily]      delete daily JSON files older than 8 days
#   [derive-context]   work out the project name and current git branch
#   [insert-session]   write the session row into SQLite
#   [active-file]      write the "current session" JSON marker file
#   [emit-reminder]    print the tracking instructions Claude must follow
# =============================================================================

# [setup] ---------------------------------------------------------------------
set -euo pipefail   # Strict mode: -e abort on error, -u unset var=error, -o pipefail = a failing command in a pipe fails the whole pipe.

# Find this script's own directory (resolves to an absolute path) so the
# `source` lines below work no matter where the script is called from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"            # defines STATE_DIR, DAILY_DIR, DB_PATH, etc.
source "$SCRIPT_DIR/lib/logging.sh"       # defines log_info / log_error
source "$SCRIPT_DIR/lib/sessions-db.sh"   # defines init_sessions_db / db_insert_session

STATE_FILE="$STATE_DIR/session-starts.json"   # rolling record of recent session starts
ACTIVE_FILE="$STATE_DIR/active-session.json"  # marker for the session running right now

# [read-input] ----------------------------------------------------------------
# Read the entire hook payload from stdin into a variable.
INPUT=$(cat)

# `jq -r '.field // empty'` = read field as raw text; if it is missing or null,
# return nothing (empty string) instead of the literal "null".
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Bail if no session ID. `[ -z "$X" ]` is true when X is an empty string;
# `&& exit 0` then quits successfully (nothing to track without an ID).
[ -z "$SESSION_ID" ] && exit 0

# Skip analyzer-spawned sessions (e.g. `claude --print` runs from the backfill
# worker). `${LOGBOOK_ANALYZER:-}` expands to the var's value, or "" if unset
# (the `:-` default avoids an "unbound variable" error under `set -u`).
[ "${LOGBOOK_ANALYZER:-}" = "1" ] && exit 0

# [state-bookkeeping] ---------------------------------------------------------
# Ensure state dir and file exist. `[ -f "$X" ] || ...` = if file is missing,
# run the right-hand side, seeding the file with an empty JSON object `{}`.
mkdir -p "$STATE_DIR"
[ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"

# Full ISO timestamp stays UTC (machine record); the `date` column uses the
# LOCAL date (2026-06-12 fix) so day boundaries match the morning review —
# with -u, sessions started 00:00–02:00 CEST landed on the previous day.
STARTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TODAY=$(date +"%Y-%m-%d")

# Compute a cutoff timestamp 7 days in the past (portable_date wraps the
# platform differences between GNU and BSD `date`); used to drop stale entries.
CUTOFF=$(portable_date "-7 days" "%Y-%m-%dT%H:%M:%SZ")

# Rewrite the state file: add this session, then drop entries older than CUTOFF.
# We write to a temp file first and `mv` over the original so a crash mid-write
# can't leave a half-written (corrupt) JSON file.
TMP_FILE=$(mktemp)
# The `--arg name value` flags pass shell variables safely into the jq program
# below as $name (jq quotes them, so spaces/quotes can't break the script).
jq --arg sid "$SESSION_ID" \
   --arg started "$STARTED_AT" \
   --arg cwd "$CWD" \
   --arg cutoff "$CUTOFF" '
  # `.` is the current JSON object. Add a new key named after the session id,
  # whose value records when it started and from which directory.
  . + { ($sid): { "started_at": $started, "cwd": $cwd } }
  # Then, if we have a cutoff, keep only entries newer than it. `with_entries`
  # maps over each key/value pair; `select(...)` drops the ones that fail.
  | if $cutoff != "" then
      with_entries(select(.value.started_at >= $cutoff))
    else . end
' "$STATE_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$STATE_FILE"

# [prune-daily] ---------------------------------------------------------------
# Delete daily JSON files older than 12 days so the daily/ dir doesn't grow
# forever. 12, not 8 (2026-06-12 fix): the morning-review lookback is 10 days,
# and an 8-day prune deleted intention/reflection/PR data for days that were
# still reviewable (deferred days lost their context).
CUTOFF_DATE=$(portable_date "-12 days" "%Y-%m-%d")
if [ -n "$CUTOFF_DATE" ]; then               # only proceed if portable_date succeeded
  for f in "$DAILY_DIR"/*.json; do
    [ -f "$f" ] || continue                  # skip if the glob matched nothing (no files)
    # Strip the directory and the ".json" extension to get just the date string,
    # e.g. "/path/daily/2026-05-20.json" -> "2026-05-20".
    FILE_DATE=$(basename "$f" | sed 's/\.[^.]*$//')
    # `[[ "$a" < "$b" ]]` here is a string comparison; because the dates are in
    # YYYY-MM-DD form, lexical order equals chronological order. Older => delete.
    [[ "$FILE_DATE" < "$CUTOFF_DATE" ]] && rm -f "$f"
  done
fi

# [derive-context] ------------------------------------------------------------
# Derive a human-friendly project name from the working directory (helper in config.sh).
PROJECT_NAME=""
if [ -n "$CWD" ]; then                       # `[ -n "$X" ]` = true when X is non-empty
  PROJECT_NAME=$(derive_project_name "$CWD")
fi

# Detect the current git branch. `git -C "$CWD"` runs git as if inside that dir.
# `2>/dev/null || echo ""` swallows errors (e.g. not a git repo) and yields "".
GIT_BRANCH=""
if [ -n "$CWD" ]; then
  GIT_BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null || echo "")
fi

# [insert-session] ------------------------------------------------------------
init_sessions_db   # create the sessions table if it doesn't exist yet

# Mark stale in_progress sessions as done (abandoned).
# Sessions stuck for >2 hours without SessionEnd firing were likely killed or crashed.
# `sqlite3 "$DB_PATH" "<SQL>"` runs the SQL against the database file. The
# trailing `|| log_error ...` logs a message if the command fails.
sqlite3 "$DB_PATH" "
  UPDATE sessions SET status = 'done'
  WHERE status = 'in_progress'
    AND session_id != '$SESSION_ID'
    AND created_at < datetime('now', '-2 hours');
" || log_error "failed to mark stale sessions"

# Insert the row for this new session (helper builds and runs the INSERT).
db_insert_session "$SESSION_ID" "$PROJECT_NAME" "$TODAY" "$GIT_BRANCH"

log_info "session started session=$SESSION_ID project=$PROJECT_NAME branch=$GIT_BRANCH"

# [active-file] ---------------------------------------------------------------
# Write the "currently active session" marker file. `jq -n` builds a brand-new
# JSON document from scratch (no input), using the --arg values below.
jq -n \
  --arg sid "$SESSION_ID" \
  --arg project "$PROJECT_NAME" \
  --arg started "$STARTED_AT" \
  --arg cwd "$CWD" \
  --arg branch "$GIT_BRANCH" '{
  session_id: $sid,
  project_name: $project,
  started_at: $started,
  cwd: $cwd,
  git_branch: $branch
}' > "$ACTIVE_FILE"

# [emit-reminder] -------------------------------------------------------------
# Print the tracking instructions on stdout. Claude Code feeds a SessionStart
# hook's stdout back to Claude as a system reminder, so this here-doc is how the
# script "talks to" Claude. A here-doc (`<< TOKEN ... TOKEN`) streams every line
# up to the closing token as the command's input; because the token is NOT
# quoted, ${SESSION_ID}, ${PROJECT_NAME} and ${DB_PATH} are substituted with
# their real values before the text is emitted.
# Kept deliberately short (2026-06-12): this text is paid context in EVERY
# session of EVERY project. Metrics, name, description, and branch are all
# populated by session-end.sh from the transcript; the one live update that is
# load-bearing is the `skill` column — it feeds the worker's read-only-skill
# flag exemptions when transcript-derivation fails (see EFFECTIVE_SKILL).
cat << INSTRUCTIONS_EOF
<session-tracking>
Session ID: ${SESSION_ID} | Project: ${PROJECT_NAME} | DB: ${DB_PATH}
All session metadata is auto-populated at session end. ONE live update matters:
when a skill is invoked, run silently (no mention to the user, no permission ask):
  sqlite3 ${DB_PATH} "UPDATE sessions SET skill = '<skill_name>' WHERE session_id = '${SESSION_ID}'"
Optionally update name the same way once the goal is clear (escape ' by doubling).
</session-tracking>
INSTRUCTIONS_EOF
