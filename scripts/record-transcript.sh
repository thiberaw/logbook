#!/usr/bin/env bash
# =============================================================================
# record-transcript.sh — ingest an external Claude Code transcript  [ENTRY POINT]
#
# WHAT IT IS:  the generic "record a session from another tool" command. Any
#              tool that drives Claude and leaves a Claude Code-format transcript
#              JSONL on disk (an editor plugin, a wrapper script, another agent)
#              can hand that file here and get a row identical to a CLI session:
#              cost, turns, tool calls, errors, files, the narrative, flagging.
# ITS JOB:     insert a row keyed by the transcript's own session id, then run
#              the exact same analysis the SessionEnd hook runs for CLI sessions
#              (session-end-worker.sh), pointed at the given transcript.
# WHY:         docs/integrations.md documents the minimal path (a bare INSERT,
#              which leaves metrics empty). This is the full-parity path — it is
#              tool-agnostic: it knows nothing about where the transcript came
#              from, only how to read one.
# INPUT:       args:  <transcript_path> [--source <tag>]
#                <transcript_path>  a Claude Code-format .jsonl transcript
#                --source <tag>     optional origin label, appended to the row
#                                   name so external rows stay recognisable in
#                                   reports (e.g. "[my-app] … [codecompanion]")
# IT CALLS:    config.sh (paths + derive_project_name), lib/sessions-db.sh,
#              session-end-worker.sh (the shared analysis worker).
# =============================================================================
set -euo pipefail   # -e abort on error, -u unset=error, -o pipefail

# [setup] ---------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"            # paths + derive_project_name
source "$SCRIPT_DIR/lib/logging.sh"       # log_info / log_warn / log_error
source "$SCRIPT_DIR/lib/sessions-db.sh"   # db_* SQLite helpers

usage() {
  echo "usage: logbook record-transcript <transcript.jsonl> [--source <tag>]" >&2
}

# [args] ----------------------------------------------------------------------
# One positional transcript path plus an optional --source <tag>.
TRANSCRIPT_PATH=""
SOURCE_TAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --source) SOURCE_TAG="${2:-}"; shift 2 || { usage; exit 1; } ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "record-transcript: unknown option '$1'" >&2; usage; exit 1 ;;
    *)  [ -z "$TRANSCRIPT_PATH" ] && TRANSCRIPT_PATH="$1" || { echo "record-transcript: unexpected extra argument '$1'" >&2; usage; exit 1; }; shift ;;
  esac
done

# [guards] --------------------------------------------------------------------
[ -n "$TRANSCRIPT_PATH" ] || { echo "record-transcript: no transcript path given" >&2; usage; exit 1; }
[ -f "$TRANSCRIPT_PATH" ] || { echo "record-transcript: no such file: $TRANSCRIPT_PATH" >&2; exit 1; }

# [identity] ------------------------------------------------------------------
# The session id and cwd come from the transcript itself — Claude Code writes
# both into each entry. Prefer the transcript's sessionId; fall back to the
# filename (Claude names the file after the session id).
SESSION_ID=$(jq -r 'select(.sessionId != null) | .sessionId' "$TRANSCRIPT_PATH" 2>/dev/null | head -1 || true)
[ -n "$SESSION_ID" ] || SESSION_ID=$(basename "$TRANSCRIPT_PATH" .jsonl)
[ -n "$SESSION_ID" ] || { echo "record-transcript: could not determine a session id" >&2; exit 1; }

CWD=$(jq -r 'select(.cwd != null) | .cwd' "$TRANSCRIPT_PATH" 2>/dev/null | head -1 || true)

# Day bucket = the LOCAL date of the first entry (so it lines up with the
# morning review and the CLI hook, both of which bucket by local date).
FIRST_TS=$(jq -r 'select(.timestamp != null) | .timestamp' "$TRANSCRIPT_PATH" 2>/dev/null | sort | head -1 || true)
DATE=$(date -d "$FIRST_TS" +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)

# Project name for the initial row (the worker re-derives + overwrites it, but
# db_insert_session needs a value for the placeholder name). Only derive when we
# have a cwd — derive_project_name shells out to git, which needs a real path.
PROJECT=""
[ -n "$CWD" ] && PROJECT=$(derive_project_name "$CWD")

# [insert + analyze] ----------------------------------------------------------
# The worker UPDATEs an existing row (keyed by session id), so the row must
# exist first. INSERT OR IGNORE makes a re-run a harmless no-op on the insert;
# re-running the worker then simply refreshes the metrics from the transcript.
# `>/dev/null` hides sqlite's `PRAGMA journal_mode=WAL` echo so the command's
# own stdout stays clean (just the final "recorded:" line).
init_sessions_db >/dev/null 2>&1
db_insert_session "$SESSION_ID" "$PROJECT" "$DATE" ""

log_info "record-transcript: session=$SESSION_ID project=${PROJECT:-?} date=$DATE src=${SOURCE_TAG:-none}"

# Run the SAME analysis the SessionEnd hook runs, synchronously (so we can tag
# and report afterwards). The worker parses the transcript for metrics, writes
# the narrative, detects flags, and persists everything. Its chatter goes to the
# log file, exactly as session-end.sh routes it, keeping our stdout clean.
if ! bash "$SCRIPT_DIR/session-end-worker.sh" "$SESSION_ID" "$TRANSCRIPT_PATH" "$CWD" >>"$LOG_FILE" 2>&1; then
  log_warn "record-transcript: worker exited non-zero for $SESSION_ID"
fi

# [result] --------------------------------------------------------------------
# The worker drops rows with no real interaction (empty-session guard). If the
# row is gone, there was nothing to record — say so and stop.
STATUS=$(db_get_field "$SESSION_ID" "status" || true)
if [ -z "$STATUS" ]; then
  echo "record-transcript: no recordable activity in $TRANSCRIPT_PATH (no row written)"
  exit 0
fi

# Optional origin tag: append it to the row name so external rows are
# recognisable in reports. The worker rebuilds the name fresh each run (without
# the tag), so appending once here stays idempotent across re-runs.
if [ -n "$SOURCE_TAG" ]; then
  CURRENT_NAME=$(db_get_field "$SESSION_ID" "name" || true)
  db_update_field "$SESSION_ID" "name" "$CURRENT_NAME [$SOURCE_TAG]"
fi

# Print a one-line confirmation built from the recorded row.
FINAL_NAME=$(db_get_field "$SESSION_ID" "name" || true)
echo "recorded: $FINAL_NAME"
