#!/usr/bin/env bash
# =============================================================================
# sessions-db.sh — SQLite access layer for session tracking  [LIBRARY — sourced, not run]
#
# WHAT IT IS:  every read/write of the sessions database goes through the small
#              wrapper functions here, so no other script writes raw SQL.
# SOURCED BY:  session-start.sh, session-end.sh, session-end-worker.sh,
#              morning-review.sh, backfill-sessions.sh, daily-report.sh,
#              weekly-summary.sh. Source config.sh first
#              (this file needs $STATE_DIR).
# PROVIDES:    init_sessions_db          — create the db/table if missing (+migrations)
#              db_insert_session         — add a new "in progress" row at session start
#              db_delete_session         — remove one row by session_id
#              db_delete_empty_sessions  — prune finished-but-empty rows
#              db_update_field           — set one column for one session
#              db_get_field              — read one column for one session
#              db_update_metrics         — write the end-of-session metrics + flags
#              db_update_description      — overwrite the description column
#              db_query_sessions_for_date  — all rows for a given date (JSON)
#              db_query_sessions_for_range — all rows in a date range (JSON)
#              _db_select                — internal: the shared SELECT (leading _ = "private")
#
# SQL-INJECTION NOTE: sqlite has no parameter binding here, so every value that
# could contain a quote is escaped with `sed "s/'/''/g"` (SQL escapes a single
# quote by doubling it). That's why you see that sed sprinkled through the writes.
# =============================================================================

# Path to the database file (lives in the gitignored .state/ runtime dir).
DB_PATH="$STATE_DIR/sessions.db"

# init_sessions_db — create the DB file + `sessions` table if they don't exist.
# Safe to call every run (CREATE TABLE IF NOT EXISTS + ignored ALTERs).
init_sessions_db() {
  mkdir -p "$STATE_DIR"
  # `<<'SQL' ... SQL` is a here-doc: everything up to the closing SQL is fed to
  # sqlite3 as input. Quoting the opening tag ('SQL') means no $-expansion inside.
  sqlite3 "$DB_PATH" <<'SQL'
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS sessions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT UNIQUE NOT NULL,
  name TEXT DEFAULT '',
  project TEXT DEFAULT '',
  date TEXT NOT NULL,
  duration INTEGER DEFAULT 0,
  cost REAL DEFAULT 0,
  branch TEXT DEFAULT '',
  skill TEXT DEFAULT '',
  status TEXT DEFAULT 'in_progress',
  turns INTEGER DEFAULT 0,
  tool_calls INTEGER DEFAULT 0,
  tool_errors INTEGER DEFAULT 0,
  files_modified INTEGER DEFAULT 0,
  flagged INTEGER DEFAULT 0,
  issue TEXT DEFAULT '',
  suggestion TEXT DEFAULT '',
  description TEXT DEFAULT '',
  first_prompt TEXT DEFAULT '',
  task_type TEXT DEFAULT '',
  outcome TEXT DEFAULT '',
  narrative_confidence TEXT DEFAULT '',
  narrative_issues TEXT DEFAULT '',
  meta_cost REAL DEFAULT 0,
  created_at TEXT DEFAULT (datetime('now'))
);
SQL
  # Migrations for databases created before these columns existed. ALTER fails if
  # the column is already there, so `2>/dev/null || true` swallows that error and
  # keeps the function idempotent (re-runnable without blowing up under `set -e`).
  sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN first_prompt TEXT DEFAULT '';" 2>/dev/null || true
  sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN task_type TEXT DEFAULT '';" 2>/dev/null || true
  sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN outcome TEXT DEFAULT '';" 2>/dev/null || true
  # 2026-06-12: heuristic_flagged = the pre-LLM flag verdict (the sonnet pass may
  # clear `flagged` but never touches this), feeding the calibration watchdog;
  # flag_feedback = the user's morning-review verdict on a flag ('correct'/'wrong'),
  # accumulating labeled data for the flag-analysis golden corpus.
  sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN heuristic_flagged INTEGER DEFAULT 0;" 2>/dev/null || true
  sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN flag_feedback TEXT DEFAULT '';" 2>/dev/null || true
  # 2026-06-17: narrative_confidence ('high'/'low') = deterministic cross-check of
  # the LLM narrative against known metrics (lib/narrative-check.sh); a 'low'
  # narrative contradicts the facts (e.g. cites a commit that doesn't exist) and
  # should be marked, not trusted. narrative_issues holds the contradictions.
  sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN narrative_confidence TEXT DEFAULT '';" 2>/dev/null || true
  sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN narrative_issues TEXT DEFAULT '';" 2>/dev/null || true
  # 2026-07-01: meta_cost = the pipeline's OWN spend on this session (the haiku
  # narrative + sonnet flag-analysis calls in session-end-worker.sh). The `cost`
  # column tracks only the user's interactive session; meta_cost makes the
  # self-reflection overhead visible so watch-metrics can report it as a fraction
  # of total spend. Populated going forward only (pre-instrumentation rows = 0).
  sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN meta_cost REAL DEFAULT 0;" 2>/dev/null || true
}

# _db_select — internal shared SELECT. arg: a SQL WHERE clause. Prints a JSON array.
# The `... AS Name` aliases rename columns to the capitalized keys the jq consumers
# elsewhere expect (e.g. `.Name`, `.Cost`). Leading underscore = "internal helper".
_db_select() {
  local where_clause="$1"
  local result
  # `sqlite3 -json` outputs rows as a JSON array. `\"Session ID\"` escapes the
  # double-quotes so SQLite treats it as a column alias containing a space.
  result=$(sqlite3 -json "$DB_PATH" "
    SELECT name AS Name, project AS Project, date AS Date, duration AS Duration,
           ROUND(cost, 3) AS Cost, branch AS Branch, skill AS Skill, description AS Description,
           turns AS Turns, tool_calls AS Tool_Calls, tool_errors AS Tool_Errors,
           files_modified AS Files_Modified, flagged AS Flagged, issue AS Issue,
           suggestion AS Suggestion, session_id AS \"Session ID\",
           first_prompt AS First_Prompt, task_type AS Task_Type, outcome AS Outcome,
           narrative_confidence AS Narrative_Confidence, narrative_issues AS Narrative_Issues
    FROM sessions WHERE $where_clause ORDER BY created_at;
  " 2>/dev/null) || true
  # sqlite3 -json prints NOTHING (not "[]") when no rows match, which would break
  # downstream jq. Normalize an empty result to a valid empty JSON array.
  if [ -z "$result" ]; then
    echo "[]"
  else
    echo "$result"
  fi
}

# db_insert_session — add a fresh row when a session starts. args: id, project,
# date, branch. INSERT OR IGNORE = do nothing if this session_id already exists
# (the UNIQUE constraint), so re-runs are harmless. The name starts as a
# placeholder "[project] (in progress)" until the worker fills in a real one.
db_insert_session() {
  local session_id="$1" project="$2" date="$3" branch="$4"
  sqlite3 "$DB_PATH" "
    INSERT OR IGNORE INTO sessions (session_id, project, date, branch, name)
    VALUES ('$session_id', '$(echo "$project" | sed "s/'/''/g")', '$date', '$(echo "$branch" | sed "s/'/''/g")', '[${project}] (in progress)');
  "
}

# db_delete_session — remove one row by session_id.
db_delete_session() {
  local session_id="$1"
  sqlite3 "$DB_PATH" "DELETE FROM sessions WHERE session_id = '$session_id';"
}

# db_delete_empty_sessions — prune rows that finished ('done') but recorded no
# real activity (no duration/cost/description/prompt) — e.g. instant /exit
# sessions — so they don't clutter the morning review.
# 48h age guard (2026-06-12): a worker crash leaves exactly this row shape, and
# pruning it destroys the only evidence the session existed (how the flagged
# $76.83 session vanished on 2026-06-09). Recent stubs stay visible so a death
# can be noticed and backfilled (scripts/backfill-sessions.sh) before pruning.
db_delete_empty_sessions() {
  sqlite3 "$DB_PATH" "
    DELETE FROM sessions
    WHERE status = 'done'
      AND duration = 0
      AND cost = 0
      AND description = ''
      AND first_prompt = ''
      AND created_at < datetime('now', '-48 hours');
  "
}

# db_update_field — set ONE column for ONE session. args: session_id, field, value.
# NOTE: `field` is interpolated straight into the SQL (it's a trusted, code-supplied
# column name, never user input); only `value` is escaped.
db_update_field() {
  local session_id="$1" field="$2" value="$3"
  sqlite3 "$DB_PATH" "
    UPDATE sessions SET $field = '$(echo "$value" | sed "s/'/''/g")'
    WHERE session_id = '$session_id';
  "
}

# db_get_field — read one column for one session; prints empty string for NULL/missing.
# args: session_id, field. COALESCE($field,'') turns a NULL into '' so callers
# always get a plain string. `LIMIT 1` since session_id is unique.
db_get_field() {
  local session_id="$1" field="$2"
  sqlite3 "$DB_PATH" "
    SELECT COALESCE($field, '') FROM sessions
    WHERE session_id = '$session_id' LIMIT 1;
  " 2>/dev/null
}

# db_update_metrics — write the end-of-session numbers + flag analysis in one go,
# and mark the row 'done'. Called by the worker. args (in order):
#   session_id, duration, cost, turns, tool_calls, tool_errors, files_modified,
#   flagged, issue, suggestion, [first_prompt]
# `${10}` / `${11:-}` : positional args past 9 need braces; `:-` defaults the
# optional first_prompt to empty. first_prompt is capped at 500 chars (substring —
# not `head -c`, which can SIGPIPE-kill the caller under pipefail).
db_update_metrics() {
  local session_id="$1" duration="$2" cost="$3" turns="$4"
  local tool_calls="$5" tool_errors="$6" files_modified="$7"
  local flagged="$8" issue="$9" suggestion="${10}" first_prompt="${11:-}"
  sqlite3 "$DB_PATH" "
    UPDATE sessions SET
      duration = $duration,
      cost = $cost,
      turns = $turns,
      tool_calls = $tool_calls,
      tool_errors = $tool_errors,
      files_modified = $files_modified,
      flagged = $flagged,
      issue = '$(echo "$issue" | sed "s/'/''/g")',
      suggestion = '$(echo "$suggestion" | sed "s/'/''/g")',
      first_prompt = '$(printf '%s' "${first_prompt:0:500}" | sed "s/'/''/g")',
      status = 'done'
    WHERE session_id = '$session_id';
  "
}

# db_update_description — overwrite just the description column. args: session_id, text.
db_update_description() {
  local session_id="$1" description="$2"
  sqlite3 "$DB_PATH" "
    UPDATE sessions SET description = '$(echo "$description" | sed "s/'/''/g")'
    WHERE session_id = '$session_id';
  "
}

# db_query_sessions_for_date — all sessions on one date (YYYY-MM-DD). Prints JSON.
db_query_sessions_for_date() {
  local date="$1"
  _db_select "date = '$date'"
}

# db_query_sessions_for_range — all sessions between two dates inclusive. Prints JSON.
db_query_sessions_for_range() {
  local from="$1" to="$2"
  _db_select "date BETWEEN '$from' AND '$to'"
}

# db_flag_calibration — heuristic flag fires vs LLM-confirmed flags over the
# trailing N days. Prints "fires|confirms". Used by the morning-review
# calibration watchdog: a confirm rate stuck at ~0% or >40% on enough fires
# means the flag-analysis prompt drifted, not that sessions changed.
db_flag_calibration() {
  local days="$1"
  sqlite3 "$DB_PATH" "
    SELECT COALESCE(SUM(heuristic_flagged), 0)
           || '|' ||
           COALESCE(SUM(CASE WHEN heuristic_flagged = 1 THEN flagged ELSE 0 END), 0)
    FROM sessions
    WHERE date >= date('now', '-$days days');
  "
}
