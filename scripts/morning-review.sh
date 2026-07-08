#!/usr/bin/env bash
# =============================================================================
# morning-review.sh — interactive "good morning" review TUI  [ENTRY POINT]
#
# WHAT IT IS : the script tmuxinator runs when you open your dev-log project
#              each morning. It walks you through reviewing recent work days.
# ITS JOB    : find weekdays that haven't been reviewed yet, show each day's
#              sessions/PRs, let you approve (with a reflection note) / defer /
#              skip via gum prompts, capture today's intention, generate the
#              reviewed report, then auto-commit + push and open the reports.
# INPUT      : none (no args/stdin) — it reads the SQLite DB and daily JSON.
# IT CALLS   : gum (the TUI prompt tool), jq, git, the lib/*.sh helpers, and
#              lib/daily-report.sh to render each reviewed day's markdown.
#
# HOW TO READ THIS FILE — runs top to bottom, in these sections:
#   [idempotency check]   bail out early if already run today
#   [fetch sessions]      load the last 10 days of sessions from SQLite
#   [find unreviewed]     pick weekdays with sessions and no reviewed/*.md
#   [review loop]         per day: enrich w/ PRs, display, prompt approve/skip
#   [daily intention]     ask for today's intention, store in daily JSON
#   [commit + push]       stage the touched files, commit, push
#   [open reviewed]       open each newly reviewed markdown in the browser
#   [~/.claude check]     Mondays only: warn if ~/.claude has uncommitted edits
#   [improve reminder]    nudge to run /improve if not done today
# =============================================================================

# Strict mode. -e: abort on first error; -u: using an unset variable is an
# error; -o pipefail: a pipeline fails if ANY stage fails (not just the last).
set -euo pipefail

# Hard requirement: gum is the TUI tool used for every prompt below. If it's
# not on PATH, print an error to stderr (`>&2`) and exit. The `{ ...; }` groups
# the two commands so both run when the `||` fires.
command -v gum >/dev/null 2>&1 || { echo "Error: gum is required but not installed. See https://github.com/charmbracelet/gum" >&2; exit 1; }

# Absolute path to this script's own directory, so sourcing works from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Pull in shared config + helper libraries. What each provides:
#   config.sh              → paths: STATE_DIR, DAILY_DIR, REVIEWED_DIR, DATA_DIR
#   logging.sh             → log_info
#   git-activity.sh        → scan_pull_requests
#   i18n.sh                → the I18N_* display strings
#   article-suggestions.sh → _select_articles, _write_articles_to_daily
#   sessions-db.sh         → init_sessions_db, db_query_*
#   session-utils.sh       → render_session_list, render_improvement_signals
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/git-activity.sh"
source "$SCRIPT_DIR/lib/i18n.sh"
source "$SCRIPT_DIR/lib/article-suggestions.sh"
source "$SCRIPT_DIR/lib/sessions-db.sh"
source "$SCRIPT_DIR/lib/session-utils.sh"

# Helper: inject article suggestions into one day's daily JSON before its report
# is generated. Returns early (success) if there's nothing to do.
_inject_articles_for_date() {
  local daily_file="$1"
  local cache_file="$STATE_DIR/articles-cache.json"
  # `[ -f X ] || return 0`: if the file is missing, quietly stop (not an error).
  [ -f "$cache_file" ] || return 0
  [ -f "$daily_file" ] || return 0

  # Refresh the article cache if it's older than 360 minutes (6 hours).
  # `find -mmin +360` prints the file only when it's that stale; the `[ "..." ]`
  # is true only when that print produced output.
  if [ "$(find "$cache_file" -mmin +360 2>/dev/null)" ]; then
    bash "$SCRIPT_DIR/lib/fetch-articles.sh" 2>/dev/null || true
  fi

  # _select_articles sets the _sa_* variables used on the next line; if it
  # fails (e.g. nothing to pick) we just return success and skip writing.
  _select_articles || return 0
  _write_articles_to_daily "$daily_file" "$_sa_releases" "$_sa_selected" "$_sa_seen_file"
}


# Export so the enrich_daily subshell (a child `bash -c`) inherits these paths.
export SCRIPT_DIR DAILY_DIR

# Stamp file: holds the date we last ran (used by the idempotency check below).
LAST_REVIEW_FILE="$STATE_DIR/last-review-date"
# GitHub blob base for the open-in-browser step, derived from the data repo's
# origin remote. Only github.com remotes are supported: anything else (GitLab,
# self-hosted, no remote, not a git repo) leaves GITHUB_BASE empty and the
# browser-open step is skipped silently — files are still written/committed.
GITHUB_BASE=""
GH_REPO_SLUG=""
GH_BRANCH=""
_remote=$(git -C "$DATA_DIR" remote get-url origin 2>/dev/null) || true
if printf '%s' "${_remote:-}" | grep -qE '^(git@github\.com:|https://github\.com/)'; then
  GH_REPO_SLUG=$(printf '%s' "$_remote" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
  GH_BRANCH=$(git -C "$DATA_DIR" branch --show-current 2>/dev/null || true)
  [ -n "$GH_BRANCH" ] || GH_BRANCH="main"
  GITHUB_BASE="https://github.com/$GH_REPO_SLUG/blob/$GH_BRANCH"
fi
unset _remote

# --- [idempotency check] -----------------------------------------------------
# Run at most once per day: if the stamp file already holds today's date, exit.
log_info "morning review started"
TODAY=$(date +"%Y-%m-%d")
PREV_REVIEW_DATE=""
[ -f "$LAST_REVIEW_FILE" ] && PREV_REVIEW_DATE=$(cat "$LAST_REVIEW_FILE")
if [ "$PREV_REVIEW_DATE" = "$TODAY" ]; then
  exit 0
fi

# day-of-week as a number, used for the Monday-only sections below.
DOW=$(date +%u)  # 1=Monday, 7=Sunday

# --- [trust checks] ----------------------------------------------------------
# Say so up front when the data feeding this review is degraded, instead of
# rendering gaps as quiet days (2026-06-12 review: silent failures rendered
# "no PRs" / "no flags" into immutable reviewed files).
# 1) GitHub reachability — PR enrichment below silently falls back to "[]".
if ! gh api rate_limit >/dev/null 2>&1; then
  gum style --foreground 214 --bold "$I18N_GH_UNREACHABLE"
fi
# 2) Worker deaths — a crashed session-end worker leaves a stub row (kept 48h)
#    that the empty-session prune below will eventually destroy. Detect deaths
#    structurally as (workers started) − (workers that logged "done"): this
#    catches ANY crash — a graceful "worker aborted", a hard bash syntax error
#    (which logs an un-timestamped stderr line the old `worker aborted` grep
#    missed, and which killed the pipeline 06-26..29), or an OOM/kill — because
#    it keys off the ABSENCE of the success marker, not on the crash logging
#    anything. Both markers are timestamped, so the window filter is reliable.
WORKER_CRASH_DETECTED=0
if [ -f "$LOG_FILE" ] && [ -n "$PREV_REVIEW_DATE" ]; then
  WORKER_STARTED=$(awk -v d="$PREV_REVIEW_DATE" 'substr($0,1,10) >= d && /session-end-worker: started/' "$LOG_FILE" | wc -l)
  WORKER_DONE=$(awk -v d="$PREV_REVIEW_DATE" 'substr($0,1,10) >= d && /session-end-worker: done/' "$LOG_FILE" | wc -l)
  WORKER_DEATHS=$(( WORKER_STARTED - WORKER_DONE ))
  [ "$WORKER_DEATHS" -lt 0 ] && WORKER_DEATHS=0
  if [ "$WORKER_DEATHS" -gt 0 ]; then
    WORKER_CRASH_DETECTED=1
    gum style --foreground 214 --bold "$(printf "$I18N_WORKER_DEATHS" "$WORKER_DEATHS")"
  fi
fi

# --- [fetch sessions] --------------------------------------------------------
# Load every session from the last 10 days in one DB query.
# date math: today minus 10 days.
RANGE_START=$(portable_date "-10 days" "%Y-%m-%d")
# ensure DB/schema exists, then drop 0-turn rows so they don't clutter the review.
# But NOT when a worker crash was detected above: a crashed worker leaves the
# exact empty-row shape the prune targets, so pruning would destroy the only
# evidence those sessions existed (06-26..29: 6 real sessions deleted this way).
# Skip the prune until the crash is fixed and the rows backfilled — the warning
# above tells the user to do so. Resumes automatically once no deaths are seen.
init_sessions_db
if [ "${WORKER_CRASH_DETECTED:-0}" -eq 1 ]; then
  log_warn "morning-review: worker crash detected — skipping empty-session prune to preserve evidence for backfill"
else
  db_delete_empty_sessions
fi
ALL_OPEN_SESSIONS=$(db_query_sessions_for_range "$RANGE_START" "$TODAY")

# Extract the distinct dates that actually have sessions, into the SESSION_DATES
# array. `mapfile -t` reads each line into an array element (-t strips newlines);
# `< <(...)` is process substitution feeding the jq output in as a file. The jq
# filter collects every .Date, de-dupes with `unique`, then emits one per line.
mapfile -t SESSION_DATES < <(printf '%s' "$ALL_OPEN_SESSIONS" | jq -r '[.[].Date] | unique | .[]')

# --- [find unreviewed] -------------------------------------------------------
# A day is unreviewed if it has sessions and no reviewed/*.md yet.
# Start with an empty array.
REVIEW_DATES=()
# Walk back day-by-day for the last 10 days. `seq 1 10` yields 1..10.
# Weekend days are NOT skipped (changed 2026-06-12): a Saturday with sessions
# deserves a review on Monday — days without sessions drop out naturally via
# the SESSION_DATES check below, so empty weekends never prompt.
for i in $(seq 1 10); do
  D=$(portable_date "-${i} days" "%Y-%m-%d")
  # Skip if a reviewed report already exists for that date.
  [ -f "$REVIEWED_DIR/$D.md" ] && continue
  # Include the date only if it appears in SESSION_DATES. The
  # `"${arr[@]+"${arr[@]}"}"` idiom safely expands the array even when empty
  # (plain "${arr[@]}" would trip `set -u` on an empty array in older bash).
  for d in "${SESSION_DATES[@]+"${SESSION_DATES[@]}"}"; do
    if [ "$d" = "$D" ]; then
      # append to the array
      REVIEW_DATES+=("$D")
      break
    fi
  done
done

# The loop above collected dates newest-first; reverse to oldest-first so the
# review walks forward in time. This counts the index down from last to 0.
SORTED_DATES=()
# `${#arr[@]}` is the array length; this counts the index down from last to 0.
for (( i=${#REVIEW_DATES[@]}-1; i>=0; i-- )); do
  SORTED_DATES+=("${REVIEW_DATES[$i]}")
done
# empty-safe array copy (the `[@]+...` guard avoids `set -u` on an empty array)
REVIEW_DATES=("${SORTED_DATES[@]+"${SORTED_DATES[@]}"}")

# Helper: scan GitHub for a day's PRs and write them into that day's daily JSON.
# Wrapped in `gum spin` so the user sees a spinner while the network calls run.
enrich_daily() {
  local review_date="$1"
  local daily_file="$DAILY_DIR/$review_date.json"
  # `gum spin --spinner dot --title "..." -- CMD`: show an animated dot spinner
  # with a title while CMD runs; the title is the localized "scanning" string
  # with the date filled in via printf. Everything after `--` is the command.
  gum spin --spinner dot --title "$(printf "$I18N_SCANNING" "$review_date")" -- \
    bash -c '
      set -uo pipefail
      source "'"$SCRIPT_DIR"'/config.sh"
      source "'"$SCRIPT_DIR"'/lib/git-activity.sh"
      REVIEW_DATE="$1"; DAILY_FILE="$2"
      PR_DATA=$(scan_pull_requests "$REVIEW_DATE" 2>/dev/null || echo "[]")
      echo "$PR_DATA" | jq . >/dev/null 2>&1 || PR_DATA="[]"
      mkdir -p "'"$DAILY_DIR"'"
      if [ -f "$DAILY_FILE" ] && [ -s "$DAILY_FILE" ]; then
        TMP=$(mktemp)
        jq --argjson prs "$PR_DATA" ".pull_requests = \$prs" "$DAILY_FILE" > "$TMP" && mv "$TMP" "$DAILY_FILE"
      else
        jq -n --arg date "$REVIEW_DATE" --argjson prs "$PR_DATA" "{date: \$date, pull_requests: \$prs}" > "$DAILY_FILE"
      fi
    ' _ "$review_date" "$daily_file" || true
  # ^ The body runs in a child bash (a subshell). The odd '"$SCRIPT_DIR"' quoting
  #   closes the single-quoted heredoc to splice in the parent's value, then
  #   reopens it. `_` becomes $0 inside; the two trailing args are $1 and $2.
  #   It scans PRs (falling back to "[]"), validates the JSON, then either sets
  #   `.pull_requests` on the existing file (via a mktemp + mv swap) or creates
  #   a fresh JSON object. `|| true` keeps a failed scan from aborting the script.
}

# --- [review loop] -----------------------------------------------------------
# If nothing needs reviewing, show a gentle "no activity" message (grey = 245).
# `${#REVIEW_DATES[@]}` is the array length.
if [ ${#REVIEW_DATES[@]} -eq 0 ]; then
  gum style --foreground 245 "$I18N_NO_ACTIVITY"
fi

# LAST_REVIEWED_DATE remembers the last day actually approved; REVIEWED_MDS
# collects the report paths created this run (opened in the browser later).
LAST_REVIEWED_DATE=""
REVIEWED_MDS=()

# First pass: enrich every candidate day with its PRs (network work up front).
if [ ${#REVIEW_DATES[@]} -gt 0 ]; then
  for REVIEW_DATE in "${REVIEW_DATES[@]}"; do
    enrich_daily "$REVIEW_DATE"
  done
fi

# Second pass: display and prompt for each day. The empty-safe expansion guards
# against `set -u` firing when there are zero dates.
for REVIEW_DATE in "${REVIEW_DATES[@]+"${REVIEW_DATES[@]}"}"; do
  DAILY_FILE="$DAILY_DIR/$REVIEW_DATE.json"

  # Pull just this date's sessions out of the pre-fetched batch (jq `select`),
  # then count them.
  DATE_SESSIONS=$(printf '%s' "$ALL_OPEN_SESSIONS" | jq --arg d "$REVIEW_DATE" '[.[] | select(.Date == $d)]')
  SESSION_COUNT=$(printf '%s' "$DATE_SESSIONS" | jq 'length')

  # Does this day have any PRs recorded? `jq '... > 0'` returns true/false.
  HAS_PRS=false
  if [ -f "$DAILY_FILE" ]; then
    HAS_PRS=$(jq '.pull_requests | length > 0' "$DAILY_FILE" 2>/dev/null || echo false)
  fi

  # Nothing to show for this day → skip it.
  if [ "$SESSION_COUNT" -eq 0 ] && [ "$HAS_PRS" = "false" ]; then
    continue
  fi

  # --- display review ---
  # wipe the terminal so each day's review starts on a clean screen
  clear
  # `gum style` draws a bordered, padded title box (212 = a pink foreground).
  gum style \
    --border normal \
    --border-foreground 212 \
    --padding "0 2" \
    --margin "1 0" \
    "$I18N_MORNING_TITLE"

  echo ""
  # When reviewing more than one day, show a "reviewing N days" subheading.
  if [ ${#REVIEW_DATES[@]} -gt 1 ]; then
    gum style --foreground 245 "$(printf "$I18N_REVIEWING_DAYS" "${#REVIEW_DATES[@]}")"
    echo ""
  fi
  gum style --foreground 212 --bold "$(printf "$I18N_ACTIVITY_FOR" "$REVIEW_DATE")"
  echo ""

  # Show the intention recorded for that day, if any. `jq -r '.intention //
  # empty'`: print the .intention field raw; if absent, print nothing.
  if [ -f "$DAILY_FILE" ]; then
    DAY_INTENTION=$(jq -r '.intention // empty' "$DAILY_FILE" 2>/dev/null)
    # `[ -n ... ]` is true when the string is non-empty; `${VAR:-}` defaults to
    # "" so `set -u` doesn't trip if it was never assigned.
    if [ -n "${DAY_INTENTION:-}" ]; then
      gum style --foreground 99 --bold "$I18N_PLANNED"
      echo "  $DAY_INTENTION"
      echo ""
    fi
  fi

  # Sessions block: heading + the rendered list + per-session improvement tips.
  if [ "$SESSION_COUNT" -gt 0 ]; then
    gum style --foreground 81 --bold "$(printf "$I18N_SESSIONS" "$SESSION_COUNT")"
    render_session_list "$DATE_SESSIONS"
    echo ""

    # Explicit flag-rate line so a day with zero flagged sessions reads as a
    # data state rather than a broken pipeline (2026-06-10 reflection: "only
    # text in gray, no warnings — something must be broken").
    FLAGGED_COUNT=$(printf '%s' "$DATE_SESSIONS" | jq '[.[] | select((.Flagged // 0) != 0 and (.Flagged // 0) != false)] | length')
    if [ "$FLAGGED_COUNT" -eq 0 ]; then
      gum style --foreground 245 "$(printf "$I18N_FLAG_RATE_OK" "$SESSION_COUNT")"
    else
      gum style --foreground 214 "$(printf "$I18N_FLAG_RATE" "$FLAGGED_COUNT" "$SESSION_COUNT")"
    fi

    # Outcome distribution (2026-06-17 review: the recorded `outcome` field was
    # never surfaced). Amber when any session ended non-success (partial /
    # abandoned / wrong_approach) — that's the day's real quality signal, which a
    # 0-flag day otherwise hides.
    OUTCOMES=$(printf '%s' "$DATE_SESSIONS" | jq -r '
      [.[] | .Outcome // "" | select(. != "")] | group_by(.) |
      map("\(length) \(.[0])") | join(" · ")')
    if [ -n "$OUTCOMES" ]; then
      NONSUCCESS=$(printf '%s' "$DATE_SESSIONS" | jq '[.[] | .Outcome // "" | select(. != "" and . != "success")] | length')
      if [ "${NONSUCCESS:-0}" -gt 0 ]; then
        gum style --foreground 214 "Outcomes: ${OUTCOMES}"
      else
        gum style --foreground 82 "Outcomes: ${OUTCOMES}"
      fi
    fi
    echo ""

    # Improvement signals (per-session actionable advice).
    gum style --foreground 214 --bold "$I18N_SIGNALS_TITLE"
    render_improvement_signals "$DATE_SESSIONS"
  fi

  # Pull requests — shown in the TUI only, never written to committed markdown.
  if [ -f "$DAILY_FILE" ]; then
    PR_COUNT=$(jq '.pull_requests // [] | length' "$DAILY_FILE" 2>/dev/null || echo 0)
    if [ "${PR_COUNT:-0}" -gt 0 ]; then
      gum style --foreground 156 --bold "$(printf "$I18N_PRS" "$PR_COUNT")"
      # jq builds one display line per PR: "[STATE] #num — title (repo)".
      # `\(...)` is jq string interpolation; `ascii_upcase` upper-cases the state.
      jq -r '.pull_requests[] | "  [\(.state | ascii_upcase)] #\(.number) — \(.title) (\(.repo))"' "$DAILY_FILE"
      echo ""
    fi
  fi

  # --- validation prompt ---
  echo ""
  # `gum choose` shows an arrow-key menu and prints the chosen option. Three
  # options: approve, review-later (defer), or skip permanently.
  CHOICE=$(gum choose "$I18N_APPROVE" "$I18N_REVIEW_LATER" "$I18N_SKIP")

  case "$CHOICE" in
    "$I18N_APPROVE")
      echo ""
      # `gum input` shows a single-line text field; --placeholder is the greyed
      # hint text. Captures a free-form reflection note for the day.
      NOTE=$(gum input --placeholder "$I18N_NOTE_PROMPT")
      if [ -n "$NOTE" ]; then
        mkdir -p "$DAILY_DIR"
        # Create a minimal daily JSON if none exists yet.
        if [ ! -f "$DAILY_FILE" ]; then
          jq -n --arg date "$REVIEW_DATE" '{date: $date}' > "$DAILY_FILE"
        fi
        # Store the note under .reflection via the mktemp + mv swap (jq can't
        # edit a file in place, so write to a temp file then move it over).
        TMP=$(mktemp)
        jq --arg note "$NOTE" '.reflection = {note: $note}' "$DAILY_FILE" > "$TMP" && mv "$TMP" "$DAILY_FILE"
      fi

      # Flag-verdict feedback (2026-06-12): one keystroke per flagged session —
      # was the flag right? Stored in the flag_feedback column. This is the
      # labeled data the flag-analysis golden corpus and calibration watchdog
      # need, captured at the moment the reviewer has the most context.
      mapfile -t FLAGGED_ROWS < <(printf '%s' "$DATE_SESSIONS" | jq -c '
        .[] | select((.Flagged // 0) != 0 and (.Flagged // 0) != false) |
        {sid: .["Session ID"], proj: (.Project // "unknown"), issue: (.Issue // "")}')
      for fb_row in "${FLAGGED_ROWS[@]+"${FLAGGED_ROWS[@]}"}"; do
        FB_SID=$(printf '%s' "$fb_row" | jq -r '.sid')
        FB_PROJ=$(printf '%s' "$fb_row" | jq -r '.proj')
        FB_ISSUE=$(printf '%s' "$fb_row" | jq -r '.issue')
        echo ""
        gum style --foreground 214 "$(printf "$I18N_FLAG_VERDICT_PROMPT" "$FB_PROJ")"
        # Show (a truncated slice of) the issue so the verdict is informed.
        [ -n "$FB_ISSUE" ] && gum style --foreground 245 "  ${FB_ISSUE:0:160}"
        FB_CHOICE=$(gum choose "$I18N_FLAG_CORRECT" "$I18N_FLAG_WRONG" "$I18N_FLAG_SKIP_ONE")
        case "$FB_CHOICE" in
          "$I18N_FLAG_CORRECT") db_update_field "$FB_SID" "flag_feedback" "correct" ;;
          "$I18N_FLAG_WRONG")   db_update_field "$FB_SID" "flag_feedback" "wrong" ;;
        esac
      done

      # Add article suggestions to the day's JSON before rendering its report.
      if [ -f "$DAILY_FILE" ]; then
        _inject_articles_for_date "$DAILY_FILE"
      fi

      # Render the markdown report straight into reviewed/ and remember its path.
      mkdir -p "$REVIEWED_DIR"
      bash "$SCRIPT_DIR/lib/daily-report.sh" "$REVIEW_DATE" "$REVIEWED_DIR"
      REVIEWED_MDS+=("reviewed/${REVIEW_DATE}.md")

      # 82 = green "saved" confirmation.
      gum style --foreground 82 "$I18N_APPROVED_SAVED"
      LAST_REVIEWED_DATE="$REVIEW_DATE"
      ;;
    "$I18N_REVIEW_LATER")
      # Defer: leave no marker, so this day reappears on the next run — but the
      # lookback window is 10 days, so a deferred day eventually drops out
      # silently. Make that expiry visible (2026-06-12).
      DAYS_LEFT=$(( 10 - ( ( $(date -d "$TODAY" +%s) - $(date -d "$REVIEW_DATE" +%s) ) / 86400 ) ))
      gum style --foreground 81 "$(printf "$I18N_DEFER_EXPIRY" "$REVIEW_DATE" "$DAYS_LEFT")"
      ;;
    "$I18N_SKIP")
      # Skip for good: write a tiny placeholder reviewed/*.md so the
      # [find unreviewed] check above treats this day as "done" next time.
      mkdir -p "$REVIEWED_DIR"
      echo "# Skipped — $REVIEW_DATE" > "$REVIEWED_DIR/$REVIEW_DATE.md"
      gum style --foreground 214 "$(printf "$I18N_SKIPPED" "$REVIEW_DATE")"
      ;;
  esac
done

# --- [daily intention] -------------------------------------------------------
# Always runs (after the reviews): ask what you intend to focus on today.
echo ""
INTENTION=$(gum input --placeholder "$I18N_INTENTION_PROMPT")
if [ -n "$INTENTION" ]; then
  TODAY_FILE="$DAILY_DIR/$TODAY.json"
  mkdir -p "$DAILY_DIR"
  # Create today's daily JSON with the intention, or patch .intention into an
  # existing file (mktemp + mv swap, since jq can't edit in place).
  if [ ! -f "$TODAY_FILE" ]; then
    jq -n --arg date "$TODAY" --arg intent "$INTENTION" '{
      date: $date, intention: $intent, pull_requests: []
    }' > "$TODAY_FILE"
  else
    TMP=$(mktemp)
    jq --arg intent "$INTENTION" '.intention = $intent' "$TODAY_FILE" > "$TMP" && mv "$TMP" "$TODAY_FILE"
  fi
  gum style --foreground 99 "$(printf "$I18N_INTENTION_SAVED" "$TODAY")"
fi

# --- [commit + push] ---------------------------------------------------------
# operate on the data dir regardless of the current directory; commit/push only
# when it is a git repo — a plain directory just keeps the written files.
cd "$DATA_DIR"
DATA_IS_GIT=false
git -C "$DATA_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 && DATA_IS_GIT=true
NEEDS_COMMIT=false

# Build an explicit allow-list of files to stage — never a blanket `git add -A`,
# so unrelated working-tree changes are left untouched.
COMMIT_FILES=()
[ -f "daily/$TODAY.json" ] && COMMIT_FILES+=("daily/$TODAY.json")
[ -f "reviewed/$TODAY.md" ] && COMMIT_FILES+=("reviewed/$TODAY.md")
# Also stage every reviewed day touched this run.
for d in "${REVIEW_DATES[@]+"${REVIEW_DATES[@]}"}"; do
  [ -f "daily/$d.json" ] && COMMIT_FILES+=("daily/$d.json")
  [ -f "reviewed/$d.md" ] && COMMIT_FILES+=("reviewed/$d.md")
done

if [ "$DATA_IS_GIT" = true ] && [ ${#COMMIT_FILES[@]} -gt 0 ]; then
  git add "${COMMIT_FILES[@]}" 2>/dev/null
  # `git diff --cached --quiet` exits non-zero when there ARE staged changes;
  # the leading `!` flips that, so NEEDS_COMMIT becomes true only if something
  # is actually staged.
  if ! git diff --cached --quiet 2>/dev/null; then
    NEEDS_COMMIT=true
  fi
fi

if [ "$NEEDS_COMMIT" = true ]; then
  git commit -m "log: daily activity for $TODAY" --quiet
  gum style --foreground 245 "$I18N_COMMITTED"
fi

PUSH_OK=false
if [ "$DATA_IS_GIT" = true ] && git -C "$DATA_DIR" remote get-url origin >/dev/null 2>&1; then
  # Push quietly. A failed push is said out loud (2026-06-12) — a silent failure
  # here means reports the user believes are published are not.
  if git push --quiet 2>/dev/null; then
    PUSH_OK=true
    gum style --foreground 245 "$I18N_PUSHED"
  else
    gum style --foreground 214 "$I18N_PUSH_FAILED"
  fi
elif [ "$DATA_IS_GIT" = false ]; then
  gum style --foreground 245 "data dir is not a git repo — files written, skipping commit/push"
fi

# --- [open reviewed] ---------------------------------------------------------
# After a successful push, open each newly reviewed report on GitHub. `xdg-open`
# launches the default browser; trailing `&` backgrounds it so the loop doesn't
# block waiting for the browser.
if [ "$PUSH_OK" = true ] && [ -n "$GITHUB_BASE" ] && [ ${#REVIEWED_MDS[@]} -gt 0 ]; then
  for md_path in "${REVIEWED_MDS[@]}"; do
    # GitHub's web/blob view can lag a push by a few seconds for a brand-new
    # path, so opening the URL the instant `git push` returns occasionally 404s
    # (2026-06-29: reviewed/2026-06-26.md opened ~1s after push, before the web
    # view served it). Wait until the contents API reports the file on the branch
    # (the API reflects the push at once), then open. The whole wait+open runs in
    # a backgrounded subshell so the review never blocks on it; if `gh` is missing
    # we open immediately (best-effort, unchanged from before).
    (
      if command -v gh >/dev/null 2>&1; then
        for _ in $(seq 1 10); do
          if gh api "repos/$GH_REPO_SLUG/contents/$md_path?ref=$GH_BRANCH" >/dev/null 2>&1; then break; fi
          sleep 1
        done
      fi
      xdg-open "$GITHUB_BASE/$md_path" 2>/dev/null
    ) &
  done
fi

# --- [~/.claude check] -------------------------------------------------------
# Notify if ~/.claude has uncommitted changes (Monday only).
# Do NOT auto-commit here: a blanket `git add -A` would sweep unrelated or
# in-progress changes into an unattended commit + push. /improve commits
# ~/.claude explicitly when it changes settings; anything else is the user's
# to review and stage by hand.
if [ "$DOW" -eq 1 ]; then
  CLAUDE_DIR="$HOME/.claude"
  # True only if it's a git repo AND `git status --porcelain` printed something
  # (porcelain = machine-readable status; non-empty means uncommitted changes).
  if [ -d "$CLAUDE_DIR/.git" ] && [ -n "$(git -C "$CLAUDE_DIR" status --porcelain 2>/dev/null)" ]; then
    echo ""
    gum style --foreground 214 --bold "$I18N_CLAUDE_DIRTY"
    # Show up to the first 20 changed lines (`head -20`); `-C DIR` runs git in
    # that directory without cd-ing there.
    git -C "$CLAUDE_DIR" status --short 2>/dev/null | head -20
  fi
fi

# --- [calibration watchdog] ----------------------------------------------------
# Meta-measurement (2026-06-12): compare heuristic flag FIRES vs LLM-CONFIRMED
# flags over the trailing 7 days. The per-day flag-rate line can't tell "zero
# flags is real" from "the flag-analysis prompt drifted and clears everything"
# (which is exactly what happened 2026-06-05..11). With enough fires, a confirm
# rate outside the 10–40% calibration band is a prompt problem, not a data state.
CALIB=$(db_flag_calibration 7 2>/dev/null || echo "0|0")
CAL_FIRES=${CALIB%%|*}      # text before the "|"
CAL_CONFIRMS=${CALIB##*|}   # text after the "|"
# Two trips. (a) fast-collapse: >=3 fires with 0 confirms is a total gate
# failure (exactly 2026-06-05..15) — warn immediately rather than waiting for
# the 5-fire statistical mass, because a broken gate ALSO starves the
# flag-feedback loop (only flagged rows get a verdict prompt) that would gather
# that mass, so the standard band check could stay blind for weeks. (b) band:
# once there's enough data, a confirm rate outside 10-40% is a prompt problem.
if [ "${CAL_FIRES:-0}" -ge 3 ] && [ "${CAL_CONFIRMS:-0}" -eq 0 ]; then
  echo ""
  gum style --foreground 214 --bold "$(printf "$I18N_CALIBRATION_WARN" "$CAL_CONFIRMS" "$CAL_FIRES" "0")"
elif [ "${CAL_FIRES:-0}" -ge 5 ]; then
  CAL_PCT=$(( CAL_CONFIRMS * 100 / CAL_FIRES ))
  if [ "$CAL_PCT" -lt 10 ] || [ "$CAL_PCT" -gt 40 ]; then
    echo ""
    gum style --foreground 214 --bold "$(printf "$I18N_CALIBRATION_WARN" "$CAL_CONFIRMS" "$CAL_FIRES" "$CAL_PCT")"
  fi
fi

# --- [watch-item evidence] ---------------------------------------------------
# Read-only: surfaces the computed half of each open-concerns watch item next to
# its threshold (scripts/watch-report.sh + docs/watch-items.json). Evidence only —
# the close/reopen decision stays with the user and /improve. Run as a subprocess
# so a registry/validation error can't abort the review; an amber line flags it.
WATCH_EXIT=0
WATCH_OUT=$("$SCRIPT_DIR/watch-report.sh" 2>"$STATE_DIR/watch-report.err") || WATCH_EXIT=$?
if [ -n "$WATCH_OUT" ]; then
  echo ""
  printf '%s\n' "$WATCH_OUT"
fi
if [ "$WATCH_EXIT" -ne 0 ] || [ -s "$STATE_DIR/watch-report.err" ]; then
  echo ""
  gum style --foreground 214 --bold "⚠ watch-report failed (exit $WATCH_EXIT): $(head -1 "$STATE_DIR/watch-report.err" 2>/dev/null || echo 'no error output')"
fi

# --- [improve reminder] ------------------------------------------------------
# /improve is run each morning right after the review, so nudge daily unless
# it has already been run today.
# stamp file written by /improve when it runs
LAST_IMPROVE_FILE="$STATE_DIR/last-improve-date"
LAST_IMPROVE=""
[ -f "$LAST_IMPROVE_FILE" ] && LAST_IMPROVE=$(cat "$LAST_IMPROVE_FILE")

echo ""
if [ "$LAST_IMPROVE" = "$TODAY" ]; then
  # already done today
  gum style --foreground 245 "$(printf "$I18N_IMPROVE_DONE" "$TODAY")"
else
  # 214 = amber nudge
  gum style --foreground 214 --bold "$I18N_IMPROVE_REMINDER"
  # If we know when it last ran, show that date too.
  [ -n "$LAST_IMPROVE" ] && gum style --foreground 245 "$(printf "$I18N_IMPROVE_RECENT" "$LAST_IMPROVE")"
fi

# --- mark done ---
# Write today's date into the stamp file so the [idempotency check] at the top
# short-circuits any further runs today.
mkdir -p "$STATE_DIR"
echo "$TODAY" > "$LAST_REVIEW_FILE"
log_info "morning review completed"
