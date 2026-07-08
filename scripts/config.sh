#!/usr/bin/env bash
# =============================================================================
# config.sh — shared paths and environment defaults  [LIBRARY — sourced, not run]
#
# WHAT IT IS:  the central config every other script pulls in first. Splits the
#              world into two roots and derives every path from them:
#                TOOL_DIR — where the engine lives (self-located, read-only)
#                DATA_DIR — where all per-user output goes (configured, writable)
# RESOLUTION:  DATA_DIR = LOGBOOK_DATA_DIR env var
#                       > ${XDG_CONFIG_HOME:-~/.config}/logbook/config
#                       > ${XDG_DATA_HOME:-~/.local/share}/logbook
# CONFIG FILE: strict KEY=value, one per line; value is the literal rest of the
#              line (no quotes, no inline # comments); blank lines and full-line
#              # comments allowed; keys whitelisted below; env always wins.
#              Values containing quotes/#/leading-trailing spaces: unsupported.
# SOURCED BY:  backfill-sessions.sh, weekly-summary.sh, session-end.sh,
#              session-start.sh, session-end-worker.sh, morning-review.sh,
#              watch-report.sh, hook-report.sh, and the lib/ helpers.
# PROVIDES:    TOOL_DIR, DATA_DIR, DAILY_DIR, REVIEWED_DIR, STATE_DIR, DOCS_DIR,
#              WEEKLY_ROOT, DATA_README, FIXTURES_DIR, GIT_USER, PROJECTS_DIR,
#              CLAUDE_PROJECTS_DIR, FALLBACK_GITHUB_REPOS(_FILE),
#              detect_github_repos, portable_date, encode_project_path,
#              find_sessions_index, derive_project_name
# =============================================================================

# `set -e` exit on any unhandled error; `-u` error on use of an unset variable;
# `-o pipefail` make a pipeline fail if ANY stage fails (not just the last one).
set -euo pipefail

# --- the two roots -----------------------------------------------------------
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Config file: sets a recognised key only if the environment did not already
# set it (env wins). Unknown keys are skipped — a bare [A-Z_] match would let
# a config file set arbitrary shell variables.
_logbook_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/logbook/config"
if [ -f "$_logbook_cfg" ]; then
  while IFS='=' read -r k v; do
    case "$k" in
      LOGBOOK_DATA_DIR|LOGBOOK_GIT_USER|LOGBOOK_PROJECTS_DIR|LOGBOOK_FIXTURES_DIR|LOGBOOK_ARTICLE_SOURCES) ;;
      *) continue ;;                     # skips blanks, "# comment" lines, unknown keys
    esac
    [ -z "${!k:-}" ] && printf -v "$k" '%s' "$v"
  done < "$_logbook_cfg"
fi
unset _logbook_cfg

DATA_DIR="${LOGBOOK_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/logbook}"

# --- identity & machine-wide locations ----------------------------------------
# Git author whose activity is tracked (PR scan, commit attribution).
GIT_USER="${LOGBOOK_GIT_USER:-$(git config user.name 2>/dev/null || true)}"
[ -n "$GIT_USER" ] || GIT_USER="$(whoami)"

# Root holding the user's git repos, used for PR scanning and project-name
# derivation. Deliberately has NO default: scanning $HOME would run a git call
# in every home subdirectory. Unset → repo auto-detection is skipped (fallback
# list / graceful no-op).
PROJECTS_DIR="${LOGBOOK_PROJECTS_DIR:-}"

# Where Claude Code stores per-project session data (transcripts, indexes).
CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"

# --- derived data paths --------------------------------------------------------
DAILY_DIR="$DATA_DIR/daily"
REVIEWED_DIR="$DATA_DIR/reviewed"
STATE_DIR="$DATA_DIR/.state"
DOCS_DIR="$DATA_DIR/docs"
WEEKLY_ROOT="$DATA_DIR"
DATA_README="$DATA_DIR/README.md"
FIXTURES_DIR="${LOGBOOK_FIXTURES_DIR:-$DATA_DIR/eval/fixtures}"

# Article sources for the morning-review suggestions: "all" (default) or a
# comma-separated whitelist of source ids — see the [fetch all sources]
# section of lib/fetch-articles.sh for the id list.
ARTICLE_SOURCES="${LOGBOOK_ARTICLE_SOURCES:-all}"

# Fallback repos for PR scanning (owner/repo format), used when PROJECTS_DIR
# is unset or holds no git repos. Lives in the gitignored state dir.
FALLBACK_GITHUB_REPOS_FILE="${FALLBACK_GITHUB_REPOS_FILE:-$STATE_DIR/fallback-repos}"
FALLBACK_GITHUB_REPOS=()
if [ -f "$FALLBACK_GITHUB_REPOS_FILE" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && [[ "$line" != \#* ]] && FALLBACK_GITHUB_REPOS+=("$line")
  done < "$FALLBACK_GITHUB_REPOS_FILE"
fi

# Auto-detect GitHub repos from git remotes under $PROJECTS_DIR/
# Returns array of "owner/repo" strings; falls back to FALLBACK_GITHUB_REPOS
# when PROJECTS_DIR is unset or yields nothing.
detect_github_repos() {
  local repos=()
  if [ -n "$PROJECTS_DIR" ] && [ -d "$PROJECTS_DIR" ]; then
    for dir in "$PROJECTS_DIR"/*/; do
      [ -d "$dir/.git" ] || continue
      local remote
      remote=$(git -C "$dir" remote get-url origin 2>/dev/null) || continue
      # Extract owner/repo from SSH or HTTPS URLs. The sed strips the leading
      # "<email>:" or "https://github.com/" and the trailing ".git", leaving
      # just "owner/repo". (`#` as sed delimiter so `/` needs no escaping.)
      local owner_repo
      owner_repo=$(echo "$remote" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
      [ -n "$owner_repo" ] && repos+=("$owner_repo")
    done
  fi
  if [ ${#repos[@]} -eq 0 ]; then
    echo "${FALLBACK_GITHUB_REPOS[@]}"
  else
    echo "${repos[@]}"
  fi
}

# Portable date arithmetic: works on both GNU and BSD date
# Usage: portable_date "+1 day" "%Y-%m-%d" ["2026-03-01"]
#   $1 = adjustment (GNU format: "+1 day", "-7 days", etc.)
#   $2 = output format
#   $3 = optional input date (default: today), format YYYY-MM-DD
portable_date() {
  local adj="$1" fmt="$2" input="${3:-}"
  if [ -n "$input" ]; then
    date -d "$input $adj" +"$fmt" 2>/dev/null && return
    # BSD: convert adjustment to -v flag (e.g., "+1 day" → -v+1d, "-7 days" → -v-7d)
    local sign num unit flag
    sign=$(echo "$adj" | grep -oE '^[+-]') || sign="+"
    num=$(echo "$adj" | grep -oE '[0-9]+')
    unit=$(echo "$adj" | grep -oE '[a-z]+' | head -1)
    flag="${unit:0:1}"  # day→d, month→m, year→y, hour→H, minute→M
    date -j -v"${sign}${num}${flag}" -f "%Y-%m-%d" "$input" +"$fmt" 2>/dev/null && return
  else
    date -d "$adj" +"$fmt" 2>/dev/null && return
    local sign num unit flag
    sign=$(echo "$adj" | grep -oE '^[+-]') || sign="+"
    num=$(echo "$adj" | grep -oE '[0-9]+')
    unit=$(echo "$adj" | grep -oE '[a-z]+' | head -1)
    flag="${unit:0:1}"
    date -j -v"${sign}${num}${flag}" +"$fmt" 2>/dev/null && return
  fi
  echo ""
}

# Encode a cwd path to Claude's project directory name format
# /home/you/projects/my-app -> -home-you-projects-my-app
encode_project_path() {
  local path="$1"
  # Replace / with - (the leading / becomes a leading -, which Claude keeps)
  echo "$path" | tr '/' '-'
}

# Find the sessions-index.json for a given project path
find_sessions_index() {
  local project_path="$1"
  local encoded
  encoded=$(encode_project_path "$project_path")
  local index_file="$CLAUDE_PROJECTS_DIR/$encoded/sessions-index.json"
  if [ -f "$index_file" ]; then
    echo "$index_file"
  fi
}

# Derive project name from cwd (relative to $PROJECTS_DIR, with git fallback)
derive_project_name() {
  local cwd="$1"
  # If path is under PROJECTS_DIR, strip prefix and take first component
  if [ -n "$PROJECTS_DIR" ] && [[ "$cwd" == "$PROJECTS_DIR/"* ]]; then
    local relative="${cwd#$PROJECTS_DIR/}"   # ${var#prefix} = strip "$PROJECTS_DIR/" off the front
    echo "${relative%%/*}"                    # ${var%%/*} = keep only the first path segment
    return
  fi
  # Handle claude-squad worktree paths:
  # ~/.claude-squad/worktrees/<user>/<task_id>/services/my-app → my-app
  if [[ "$cwd" == *"/.claude-squad/worktrees/"* ]]; then
    # Strip worktree prefix, find the repo root via git
    local remote
    remote=$(git -C "$cwd" remote get-url origin 2>/dev/null) || true
    if [ -n "$remote" ]; then
      basename "$remote" .git
      return
    fi
    # Fallback: use the deepest directory name that matches a known project repo
    if [ -n "$PROJECTS_DIR" ] && [ -d "$PROJECTS_DIR" ]; then
      local name
      for dir in "$PROJECTS_DIR"/*/; do
        name=$(basename "$dir")
        if [[ "$cwd" == *"/$name/"* ]] || [[ "$cwd" == *"/$name" ]]; then
          echo "$name"
          return
        fi
      done
    fi
  fi
  # Fallback: extract repo name from git remote URL
  local remote
  remote=$(git -C "$cwd" remote get-url origin 2>/dev/null) || true
  if [ -n "$remote" ]; then
    basename "$remote" .git
    return
  fi
  # Last resort: basename of git toplevel
  local toplevel
  toplevel=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || true
  if [ -n "$toplevel" ]; then
    basename "$toplevel"
    return
  fi
  basename "$cwd"
}
