#!/usr/bin/env bash
# =============================================================================
# logging.sh — timestamped logging helpers  [LIBRARY — sourced, not run]
#
# WHAT IT IS:  shared logging used by the other logbook scripts. It appends
#              timestamped lines to a single log file and self-rotates it.
# SOURCED BY:  scripts that need to log (e.g. fetch-articles.sh, session-*.sh),
#              always AFTER config.sh because it relies on $STATE_DIR.
# PROVIDES:    log()       — low-level writer: log <LEVEL> <message...>
#              log_info()  — convenience wrapper, writes an INFO line
#              log_warn()  — convenience wrapper, writes a WARN line
#              log_error() — convenience wrapper, writes an ERROR line
#              (on source, also rotates the log file if it grew too large)
# =============================================================================

# Where every log line is appended. $STATE_DIR comes from config.sh (sourced first).
LOG_FILE="$STATE_DIR/logbook.log"
# Name shown in each log line, identifying which script wrote it.
# `${LOG_SCRIPT:-...}` = use a caller-provided LOG_SCRIPT if set, else compute a default.
# BASH_SOURCE[1] is the file that sourced THIS library; `${...:-unknown}` falls back to
# "unknown" if that is empty. `basename ... .sh` strips the directory and the ".sh" suffix.
LOG_SCRIPT="${LOG_SCRIPT:-$(basename "${BASH_SOURCE[1]:-unknown}" .sh)}"

# Low-level writer. First argument is the level; `shift` drops it so "$*" is the message.
log() {
  local level="$1"; shift   # `local` keeps `level` scoped to this function only.
  # printf builds one line: UTC timestamp, [LEVEL] padded to 5 chars, script name, message.
  # `date -u` = UTC; `%-5s` = left-justified in a 5-wide field; `"$*"` = all remaining args
  # joined as the message. `>>` appends to the log file (never truncates).
  printf '%s [%-5s] %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$LOG_SCRIPT" "$*" >> "$LOG_FILE"
}

# Convenience wrappers. "$@" forwards all arguments through to log() unchanged.
log_info()  { log INFO "$@"; }
log_warn()  { log WARN "$@"; }
log_error() { log ERROR "$@"; }

# --- log rotation (runs once each time this file is sourced) ------------------
# Keeps the log from growing forever: when it exceeds 1000 lines, trim to the last 500.
# `[ -f "$LOG_FILE" ]` = true only if the log file already exists.
if [ -f "$LOG_FILE" ]; then
  # `wc -l < file` counts lines; reading via `<` (not `wc -l file`) avoids printing the filename.
  _log_lines=$(wc -l < "$LOG_FILE")
  # `-gt` = numeric "greater than".
  if [ "$_log_lines" -gt 1000 ]; then
    _log_tmp=$(mktemp)   # mktemp = create a unique temporary file and print its path.
    # Write the last 500 lines to the temp file, then move it over the original (atomic replace).
    # `&&` only runs `mv` if `tail` succeeded, so a failure can't blank the log.
    tail -500 "$LOG_FILE" > "$_log_tmp" && mv "$_log_tmp" "$LOG_FILE"
  fi
  unset _log_lines _log_tmp   # Drop these temporary vars so they don't leak into the caller's shell.
fi
