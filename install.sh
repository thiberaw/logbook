#!/usr/bin/env bash
# =============================================================================
# install.sh — idempotent installer / health check  [ENTRY POINT]
#
# Safe to re-run for upgrades: re-links the CLI, skills, and agent to the
# current checkout; never overwrites an existing config or any seeded/user
# file; never touches the DB once it exists. `--check` runs the health check
# only (also exposed as `logbook doctor`).
# =============================================================================
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/logbook"
CFG_FILE="$CFG_DIR/config"
BIN_LINK="$HOME/.local/bin/logbook"

# --- [dependencies] ----------------------------------------------------------
# Verified, never auto-installed. Required deps abort; recommended ones warn.
REQUIRED=(bash git jq sqlite3 python3)
RECOMMENDED=(gum gh)
missing_required=()
missing_recommended=()
for d in "${REQUIRED[@]}"; do command -v "$d" >/dev/null 2>&1 || missing_required+=("$d"); done
for d in "${RECOMMENDED[@]}"; do command -v "$d" >/dev/null 2>&1 || missing_recommended+=("$d"); done

if [ ${#missing_recommended[@]} -gt 0 ]; then
  echo "recommended tools missing: ${missing_recommended[*]}"
  echo "  gum → morning-review TUI; gh → PR scanning + GitHub browser-open"
  echo "  install e.g.: sudo apt install ${missing_recommended[*]}  /  brew install ${missing_recommended[*]}"
fi
if [ ${#missing_required[@]} -gt 0 ]; then
  echo "ERROR: required tools missing: ${missing_required[*]}" >&2
  echo "  install e.g.: sudo apt install ${missing_required[*]}  /  brew install ${missing_required[*]}" >&2
  exit 1
fi

# --- [--check mode] ------------------------------------------------------------
run_check() {
  local ok=0
  echo "logbook $(cat "$TOOL_DIR/VERSION") — health check"
  if [ -L "$BIN_LINK" ] && [ -x "$(readlink -f "$BIN_LINK")" ]; then
    echo "  ok: $BIN_LINK → $(readlink -f "$BIN_LINK")"
  else
    echo "  MISSING: $BIN_LINK symlink"; ok=1
  fi
  for s in improve daily-status; do
    if [ -L "$HOME/.claude/skills/$s" ]; then
      echo "  ok: skill symlink $s"
    else
      echo "  note: skill $s is not symlinked (run install.sh)"
    fi
  done
  if [ -f "$CFG_FILE" ]; then
    echo "  ok: config $CFG_FILE"
  else
    echo "  note: no config file (defaults + env apply)"
  fi
  # config parses + DATA_DIR resolves and is writable
  ( source "$TOOL_DIR/scripts/config.sh"
    echo "  DATA_DIR=$DATA_DIR"
    if [ -d "$DATA_DIR" ] && [ -w "$DATA_DIR" ]; then
      echo "  ok: data dir writable"
    else
      echo "  MISSING: data dir absent or not writable"; exit 1
    fi
    # morning-review commits/pushes/opens its reports from DATA_DIR; without a
    # git repo + remote that whole flow silently no-ops (reports still written).
    if git -C "$DATA_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      if git -C "$DATA_DIR" remote get-url origin >/dev/null 2>&1; then
        echo "  ok: data dir is a git repo with an origin remote"
      else
        echo "  warn: data dir has no 'origin' remote — morning-review cannot push/open reports"
      fi
    else
      echo "  warn: data dir is not a git repo — morning-review cannot commit/push/open reports"
    fi ) || ok=1
  # Session hooks wired into Claude Code? Without them no sessions are tracked.
  if [ -f "$HOME/.claude/settings.json" ] \
     && grep -q "logbook session-start" "$HOME/.claude/settings.json" 2>/dev/null \
     && grep -q "logbook session-end" "$HOME/.claude/settings.json" 2>/dev/null; then
    echo "  ok: session hooks present in settings.json"
  else
    echo "  warn: session hooks not found in ~/.claude/settings.json — session tracking will not run"
  fi
  echo "  deps: required present (${REQUIRED[*]})"
  return "$ok"
}
if [ "${1:-}" = "--check" ]; then
  run_check
  exit $?
fi

# --- [symlinks: CLI + skills + agent] ------------------------------------------
mkdir -p "$HOME/.local/bin" "$HOME/.claude/skills" "$HOME/.claude/agents"
ln -sfn "$TOOL_DIR/bin/logbook" "$BIN_LINK"
echo "linked $BIN_LINK"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "WARNING: ~/.local/bin is not on your PATH — add it or the hooks/skills cannot find 'logbook'" ;;
esac

for s in improve daily-status; do
  if [ -e "$HOME/.claude/skills/$s" ] && [ ! -L "$HOME/.claude/skills/$s" ]; then
    echo "SKIPPED skill $s: $HOME/.claude/skills/$s exists and is not a symlink — move it aside, then re-run"
  else
    ln -sfn "$TOOL_DIR/skills/$s" "$HOME/.claude/skills/$s"
    echo "linked skill $s"
  fi
done
if [ -e "$HOME/.claude/agents/daily-status.md" ] && [ ! -L "$HOME/.claude/agents/daily-status.md" ]; then
  echo "SKIPPED agent daily-status: exists and is not a symlink — move it aside, then re-run"
else
  ln -sfn "$TOOL_DIR/agents/daily-status.md" "$HOME/.claude/agents/daily-status.md"
  echo "linked agent daily-status"
fi

# --- [config: create only if absent] --------------------------------------------
if [ ! -f "$CFG_FILE" ]; then
  default_data="${XDG_DATA_HOME:-$HOME/.local/share}/logbook"
  data_dir="${LOGBOOK_DATA_DIR:-}"
  if [ -z "$data_dir" ] && [ -t 0 ]; then
    printf 'Where should logbook store your data? [%s] ' "$default_data"
    read -r data_dir
  fi
  data_dir="${data_dir:-$default_data}"
  if [ ! -t 0 ] && [ -z "${LOGBOOK_DATA_DIR:-}" ]; then
    echo "note: non-interactive install — defaulting data dir to $data_dir (set LOGBOOK_DATA_DIR to override)"
  fi

  # Article sources for the morning-review suggestions. Interactive installs
  # get a picker over the built-in sources (all preselected); non-interactive
  # installs default to all (tune LOGBOOK_ARTICLE_SOURCES later).
  ALL_SOURCES=(claude-releases claude-api-releases anthropic-news anthropic-engineering anthropic-research hn addyo simonwillison pragmaticengineer danielmiessler r-claudecode)
  article_sources=""
  if [ -t 0 ] && command -v gum >/dev/null 2>&1; then
    echo "Which sources should the morning review suggest articles from?"
    echo "(space toggles, enter confirms — all selected keeps the default)"
    picked=$(gum choose --no-limit --selected="$(IFS=,; echo "${ALL_SOURCES[*]}")" "${ALL_SOURCES[@]}" | paste -sd, -) || picked=""
    if [ -n "$picked" ] && [ "$picked" != "$(IFS=,; echo "${ALL_SOURCES[*]}")" ]; then
      article_sources="$picked"
    fi
  fi

  mkdir -p "$CFG_DIR"
  {
    echo "# logbook config — strict KEY=value, one per line, no quotes, no inline comments"
    echo "LOGBOOK_DATA_DIR=$data_dir"
    echo "# Uncomment to enable PR scanning over a directory holding ONLY your git repos:"
    echo "# LOGBOOK_PROJECTS_DIR=/home/you/projects"
    if [ -n "$article_sources" ]; then
      echo "LOGBOOK_ARTICLE_SOURCES=$article_sources"
    else
      echo "# Article sources (default all). Available ids:"
      echo "# LOGBOOK_ARTICLE_SOURCES=$(IFS=,; echo "${ALL_SOURCES[*]}")"
    fi
  } > "$CFG_FILE"
  echo "wrote $CFG_FILE"
else
  echo "config exists — untouched ($CFG_FILE)"
fi

# --- [data dir + DB + seeds: strictly if-absent] ---------------------------------
source "$TOOL_DIR/scripts/config.sh"
mkdir -p "$DATA_DIR/reviewed" "$DATA_DIR/daily" "$DATA_DIR/docs" "$DATA_DIR/.state"

# morning-review commits/pushes/opens its reports from DATA_DIR, so it must be a
# git repo with a remote or that whole flow silently no-ops. Don't force it, but
# don't leave it silent either.
if ! git -C "$DATA_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ -t 0 ]; then
    printf 'DATA_DIR (%s) is not a git repo — morning-review needs one to commit/push/open reports.\nRun `git init` there now? [y/N] ' "$DATA_DIR"
    read -r _gi_reply || _gi_reply=""
    if [ "${_gi_reply:-}" = y ] || [ "${_gi_reply:-}" = Y ]; then
      git -C "$DATA_DIR" init -q
      echo "git-initialized $DATA_DIR — add a remote to enable push/open:"
      echo "  git -C $DATA_DIR remote add origin <github-url>"
    else
      echo "left as-is — morning-review will write reports but not commit/push/open them"
    fi
  else
    echo "WARNING: DATA_DIR ($DATA_DIR) is not a git repo — morning-review cannot commit/push/open reports."
    echo "  git -C $DATA_DIR init && git -C $DATA_DIR remote add origin <github-url>"
  fi
fi

if [ ! -f "$STATE_DIR/sessions.db" ]; then
  source "$TOOL_DIR/scripts/lib/sessions-db.sh"
  init_sessions_db >/dev/null
  echo "initialized empty DB at $STATE_DIR/sessions.db"
else
  echo "DB exists — untouched"
fi

seed() {  # <path> <heredoc-content-on-stdin>
  local f="$1"
  if [ -f "$f" ]; then echo "seed exists — untouched ($f)"; else cat > "$f"; echo "seeded $f"; fi
}
seed "$DOCS_DIR/watch-items.json" <<'EOF'
[]
EOF
seed "$DOCS_DIR/open-concerns.md" <<'EOF'
# Open Concerns

Active evaluations and improvement ideas that need evidence before deciding.
/improve checks these against recent session data and appends dated
observations under each concern.

---
EOF
seed "$DATA_README" <<'EOF'
# Logbook data

Daily reviews, weekly summaries, and reflection docs written by the
[logbook](https://github.com/thiberaw/logbook) tool.

## Logs
EOF
seed "$DATA_DIR/.gitignore" <<'EOF'
.state/
EOF

# --- [hook block: printed, never auto-edited] -------------------------------------
cat <<EOF

Add to ~/.claude/settings.json hooks (absolute paths — hooks may not see ~/.local/bin on PATH):

  "SessionStart": [{ "hooks": [{ "type": "command", "command": "$BIN_LINK session-start" }] }],
  "SessionEnd":   [{ "hooks": [{ "type": "command", "command": "$BIN_LINK session-end" }] }]

If you want PR scanning in the morning review, set LOGBOOK_PROJECTS_DIR in $CFG_FILE
to a directory that holds only your git repos.

EOF
run_check
