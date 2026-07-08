#!/usr/bin/env bash
# =============================================================================
# session-end.sh — SessionEnd hook  [ENTRY POINT]
#
# WHAT IT IS:  A hook Claude Code runs automatically when a session ends.
# ITS JOB:     Kick off session analysis WITHOUT blocking. Reads the hook's
#              input, launches the real worker in the background, exits.
# INPUT:       JSON on stdin (NOT args):
#              { "session_id", "transcript_path", "cwd", "reason" }
# IT CALLS:    session-end-worker.sh (background; does metrics/narrative/flagging)
#
# HOW TO READ THIS FILE — runs straight down, in these sections:
#   [setup]        load strict mode + shared libraries
#   [read input]   parse the JSON the hook sent on stdin
#   [guards]       bail out early for cases we don't track
#   [fork worker]  launch the worker in the background and return
# =============================================================================
# SessionEnd hook: extracts transcript metrics, generates LLM narrative,
# detects flags, and writes everything to SQLite.
# Reads JSON from stdin: { "session_id": "...", "transcript_path": "...", "cwd": "...", "reason": "..." }
set -euo pipefail   # Strict mode. -e: abort on first failing command.
                    # -u: unset variable = error (catches typos).
                    # -o pipefail: a pipeline fails if ANY stage fails.

# [setup] ---------------------------------------------------------------------
# BASH_SOURCE[0] is the path to THIS script; resolve its folder so the script
# works from any directory, then load shared helpers.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"            # paths + env vars (STATE_DIR, LOG_FILE, …)
source "$SCRIPT_DIR/lib/logging.sh"       # log_info / log_warn / log_error
source "$SCRIPT_DIR/lib/sessions-db.sh"   # SQLite helper functions

# Runtime state files (paths come from config.sh's $STATE_DIR).
STATE_FILE="$STATE_DIR/session-starts.json"   # when each session started
ACTIVE_FILE="$STATE_DIR/active-session.json"  # the currently-tracked session

# [read input] ----------------------------------------------------------------
# Read hook input from stdin (must happen synchronously before hook exits)
# `cat` with no args slurps everything piped in on stdin into one string.
INPUT=$(cat)

# `jq -r '.x // empty'` = field x, raw (no quotes); if missing, return nothing.
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# [guards] --------------------------------------------------------------------
# Bail if no session ID
[ -z "$SESSION_ID" ] && exit 0   # `-z` = empty string → nothing to record.

# Skip analyzer-spawned sessions
# The worker itself launches `claude` to write narratives; that nested run sets
# LOGBOOK_ANALYZER=1 so we don't recursively analyze our own analysis sessions.
# `${VAR:-}` = VAR, or "" if unset, so strict mode's -u doesn't trip.
if [ "${LOGBOOK_ANALYZER:-}" = "1" ]; then
  exit 0
fi

# [fork worker] ---------------------------------------------------------------
# --- Run the heavy analysis in the background ---
# The hook timeout is 10s, but transcript analysis + LLM calls take much longer.
# We fork everything into a background process so the hook exits immediately.
# `${TRANSCRIPT_PATH:-(empty)}` substitutes the literal text "(empty)" when the
# variable is empty, just to make the log line readable.
log_info "hook fired session=$SESSION_ID transcript=${TRANSCRIPT_PATH:-(empty)} cwd=${CWD:-(empty)}"

#   nohup : keep running after this script exits;  & : background it (trailing &);
#   >> "$LOG_FILE" : append stdout to the log;  2>&1 : send errors there too.
nohup bash "$SCRIPT_DIR/session-end-worker.sh" \
  "$SESSION_ID" "$TRANSCRIPT_PATH" "$CWD" \
  >> "$LOG_FILE" 2>&1 &

log_info "worker forked pid=$!"   # $! = process id of the background job above

exit 0
