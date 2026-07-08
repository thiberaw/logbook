#!/usr/bin/env bash
# =============================================================================
# weekly-summary.sh — Generate the committed weekly markdown summary  [ENTRY POINT]
#
# WHAT IT IS: a standalone script you run (manually or on a schedule) to produce
#   one markdown file summarising a work week of Claude Code activity.
# ITS JOB: read the week's sessions + daily reflections, group them by ticket,
#   write a markdown file, link it from README.md, and auto-commit.
# INPUT (args): optional "$1"=Monday and "$2"=Friday (YYYY-MM-DD) to override the
#   auto-detected week. With no args it summarises the current week.
# IT CALLS: config.sh, lib/i18n.sh, lib/sessions-db.sh, lib/session-utils.sh
#   (all sourced for shared vars/helpers); the `git` CLI to commit.
#
# HOW TO READ THIS FILE — runs top to bottom, in these sections:
#   [week-range]      figure out which Mon–Fri week to summarise
#   [fetch-sessions]  pull this week's sessions out of the database
#   [collect-daily]   gather the matching daily JSON files (reflections, etc.)
#   [date-helpers]    functions + vars that format dates for display/paths
#   [parse-issues]    reshape raw session JSON into the fields we render
#   [generate-md]     write the markdown body to the output file
#   [update-readme]   add a link to the new file in README.md
#   [auto-commit]     git add + commit the result
# =============================================================================
# Generate weekly markdown summary from processed session JSON + daily JSON metadata.
# Sessions come from processed JSON files, reflections/PRs from daily JSON.
# Matches existing format: ## 2026 - from Feb. 17th to Feb. 21st

set -euo pipefail   # Strict mode. -e: abort on first error; -u: unset var = error;
                    # -o pipefail: a pipeline fails if ANY stage fails (not just the last).

# Absolute path to this script's own directory, so the `source` lines below work
# no matter what directory the script is launched from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"             # paths: DAILY_DIR, WEEKLY_ROOT, DATA_DIR, etc.
source "$SCRIPT_DIR/lib/i18n.sh"           # translated message strings (I18N_*)
source "$SCRIPT_DIR/lib/sessions-db.sh"    # init_sessions_db, db_query_sessions_for_range
source "$SCRIPT_DIR/lib/session-utils.sh"  # portable_date, get_day_totals

# [week-range] ----------------------------------------------------------------
# --- Determine the week range ---
TODAY=$(date +"%Y-%m-%d")
DOW=$(date +%u)  # Day-of-week as a number: 1=Monday ... 7=Sunday.

# Walk back to this week's Monday. If today IS Monday, use today; otherwise
# subtract (DOW-1) days. portable_date is a cross-platform `date` wrapper.
if [ "$DOW" -eq 1 ]; then
  MONDAY="$TODAY"
else
  MONDAY=$(portable_date "-$((DOW - 1)) days" "%Y-%m-%d")
fi
FRIDAY=$(portable_date "+4 days" "%Y-%m-%d" "$MONDAY")  # Friday = Monday + 4 days.

# Allow override via arguments.
# "${1:-}" means "$1, or empty string if unset" — avoids an error under `set -u`.
if [ "${1:-}" != "" ] && [ "${2:-}" != "" ]; then
  MONDAY="$1"
  FRIDAY="$2"
fi

# [fetch-sessions] ------------------------------------------------------------
# --- Fetch sessions for the week from processed JSON ---
init_sessions_db
WEEK_SESSIONS=$(db_query_sessions_for_range "$MONDAY" "$FRIDAY")  # JSON array of sessions
SESSION_COUNT=$(printf '%s' "$WEEK_SESSIONS" | jq 'length')  # `jq length` = element count

# [collect-daily] -------------------------------------------------------------
# --- Collect daily JSON files for non-session data (reflections, PRs) ---
WEEK_FILES=()        # bash array; will hold the paths of daily files that exist
CURRENT="$MONDAY"
# Loop Monday → Friday inclusive. `[[ < ]]` does lexical string comparison, which
# works correctly here because dates are zero-padded YYYY-MM-DD.
while [[ "$CURRENT" < "$FRIDAY" ]] || [[ "$CURRENT" == "$FRIDAY" ]]; do
  FILE="$DAILY_DIR/$CURRENT.json"
  [ -f "$FILE" ] && WEEK_FILES+=("$FILE")   # append the file only if it exists
  CURRENT=$(portable_date "+1 day" "%Y-%m-%d" "$CURRENT")   # advance one day
done

# Nothing to summarise (no sessions and no daily files) → exit cleanly. 0 = success.
if [ "$SESSION_COUNT" -eq 0 ] && [ ${#WEEK_FILES[@]} -eq 0 ]; then   # ${#arr[@]} = array length
  echo "No data found for week $MONDAY to $FRIDAY"
  exit 0
fi

# [date-helpers] --------------------------------------------------------------
# --- Format date helpers ---
# Return the English ordinal suffix for a day number (1->st, 2->nd, 3->rd, else th).
ordinal_suffix() {
  local day=$1
  case $day in
    1|21|31) echo "st" ;;
    2|22) echo "nd" ;;
    3|23) echo "rd" ;;
    *) echo "th" ;;
  esac
}

# Build a human display string like "Feb. 17th" from a YYYY-MM-DD date.
format_date_display() {
  local date_str="$1"
  local month_abbr day_num suffix
  # LC_ALL=en_US.UTF-8 forces English month names regardless of system locale.
  # "%b" = abbreviated month (Feb); "%-d" = day with no leading zero (7 not 07).
  month_abbr=$(LC_ALL=en_US.UTF-8 portable_date "+0 days" "%b" "$date_str")
  day_num=$(portable_date "+0 days" "%-d" "$date_str")
  suffix=$(ordinal_suffix "$day_num")
  echo "${month_abbr}. ${day_num}${suffix}"   # e.g. "Feb. 17th"
}

# Pull individual date parts off MONDAY for building the output path + heading.
YEAR=$(portable_date "+0 days" "%Y" "$MONDAY")
MONTH_NUM=$(portable_date "+0 days" "%m" "$MONDAY")
MONTH_ABBR=$(LC_ALL=en_US.UTF-8 portable_date "+0 days" "%b" "$MONDAY")
MONTH_ABBR_LOWER=$(echo "$MONTH_ABBR" | tr '[:upper:]' '[:lower:]')  # `tr` lowercases: Feb -> feb

MON_DISPLAY=$(format_date_display "$MONDAY")
FRI_DISPLAY=$(format_date_display "$FRIDAY")

MON_MM_DD=$(portable_date "+0 days" "%m-%d" "$MONDAY")   # e.g. 02-17, used in filename
FRI_MM_DD=$(portable_date "+0 days" "%m-%d" "$FRIDAY")

# Output directory and filename, e.g. <data dir>/2026/02-feb/2026_02-17_02-21.md
OUT_DIR="$WEEKLY_ROOT/$YEAR/${MONTH_NUM}-${MONTH_ABBR_LOWER}"
OUT_FILE="$OUT_DIR/${YEAR}_${MON_MM_DD}_${FRI_MM_DD}.md"

mkdir -p "$OUT_DIR"   # -p: create parent dirs as needed, no error if it exists

# [parse-issues] --------------------------------------------------------------
# --- Parse issues into structured data ---
# Extract ticket patterns from issue bodies (Branch field in metrics table)
# PR data intentionally not rendered — weekly summary is committed to a public repo.
ALL_REFLECTIONS="[]"
if [ ${#WEEK_FILES[@]} -gt 0 ]; then
  # `jq -s` (slurp) reads all daily files into one array; this keeps each file's
  # .reflection object (dropping files that have none). `|| echo "[]"` = empty
  # array fallback if jq fails so the script keeps running.
  ALL_REFLECTIONS=$(jq -s '[.[] | select(.reflection) | .reflection]' "${WEEK_FILES[@]}" 2>/dev/null || echo "[]")
fi

# Parse sessions for grouping by ticket.
# This jq maps each raw session into a small object with just the fields we need.
# `(.X // default)` = use field X, or `default` if it's null/absent.
PARSED_SESSIONS=$(printf '%s' "$WEEK_SESSIONS" | jq '
  [.[] |
    {
      project: .Project,
      description: (.Description // .Name // "session"),
      duration: (.Duration // 0),
      cost: (.Cost // 0),
      branch: (.Branch // ""),
      # Flagged means the session was marked as having a problem worth noting.
      # The DB may store it as the number 1 or the boolean true — accept either.
      flagged: ((.Flagged // 0) == 1 or (.Flagged // false) == true),
      suggestion: (if (.Flagged == 1 or .Flagged == true) then .Suggestion else null end)
    }
  ]
')

# Extract unique ticket patterns from branches.
# `capture("(?<ticket>[A-Z]+-[0-9]+)")` pulls a Jira-style key (e.g. ABC-123)
# out of each branch name; `unique` dedupes; `.[]` streams them one per line.
TICKET_GROUPS=$(printf '%s' "$PARSED_SESSIONS" | jq -r '
  [.[] | .branch | capture("(?<ticket>[A-Z]+-[0-9]+)") | .ticket] | unique | .[]
' 2>/dev/null || echo "")

# [generate-md] ---------------------------------------------------------------
# --- Generate markdown ---
# Everything inside this { ... } brace group has its combined stdout redirected
# to OUT_FILE at the very bottom (`} > "$OUT_FILE"`).
{
  echo "## $YEAR - from $MON_DISPLAY to $FRI_DISPLAY"   # section heading
  echo ""

  # Group sessions by ticket. COUNTER numbers each rendered line (1., 2., ...).
  COUNTER=1
  if [ -n "$TICKET_GROUPS" ]; then   # -n = string is non-empty
    # Read TICKET_GROUPS line by line. `IFS=` + `read -r` preserves the line
    # verbatim (no trimming, no backslash escapes).
    while IFS= read -r ticket; do
      [ -z "$ticket" ] && continue   # skip blank lines

      # All sessions whose branch contains this ticket key. `--arg t` passes the
      # shell var into jq safely as the string $t.
      TICKET_SESSIONS=$(printf '%s' "$PARSED_SESSIONS" | jq -r --arg t "$ticket" '
        [.[] | select(.branch | contains($t))]
      ')
      SESSION_COUNT=$(printf '%s' "$TICKET_SESSIONS" | jq 'length')

      if [ "$SESSION_COUNT" -gt 0 ]; then
        # `.[0]` = first session for this ticket (used for desc + project).
        TICKET_DESC=$(printf '%s' "$TICKET_SESSIONS" | jq -r '.[0].description // "In progress"')
        # `[.[] | .duration] | add` sums all durations; `// 0` guards an empty list.
        TOTAL_MINUTES=$(printf '%s' "$TICKET_SESSIONS" | jq '[.[] | .duration] | add // 0')
        PROJECT=$(printf '%s' "$TICKET_SESSIONS" | jq -r '.[0].project // "unknown"')

        echo "${COUNTER}. **${ticket}** — ${TICKET_DESC} (${PROJECT}, ${TOTAL_MINUTES}m)"
        COUNTER=$((COUNTER + 1))   # $(( )) = arithmetic; increment the line counter
      fi
    done <<< "$TICKET_GROUPS"   # `<<<` feeds the string into the loop's stdin (a here-string)
  fi

  # Sessions without ticket patterns (i.e. branches with no Jira key).
  # `--argjson tickets ...` passes the ticket list to jq as a real JSON array
  # (built by `jq -R -s 'split("\n")...'`: read raw, slurp, split on newlines,
  # drop empties). A session is "untagged" if its branch contains NONE of the
  # known tickets, and it has a real description (not blank / the word "session").
  UNTAGGED=$(printf '%s' "$PARSED_SESSIONS" | jq -r --argjson tickets "$(printf '%s' "$TICKET_GROUPS" | jq -R -s 'split("\n") | map(select(. != ""))')" '
    [.[] | select(
      (.branch) as $b |
      ($tickets | all(. as $t | $b | contains($t) | not))
    ) | select(.description != "" and .description != "session")]
  ')
  UNTAGGED_COUNT=$(printf '%s' "$UNTAGGED" | jq 'length')

  if [ "$UNTAGGED_COUNT" -gt 0 ]; then
    # Emit "project: description" per untagged session, numbering continues from COUNTER.
    printf '%s' "$UNTAGGED" | jq -r '.[] | "\(.project): \(.description)"' | while IFS= read -r line; do
      [ -z "$line" ] && continue
      echo "${COUNTER}. ${line}"
      COUNTER=$((COUNTER + 1))
    done
  fi

  # Notes from reflections: collect every non-empty `.note`, dedupe, one per line.
  NOTES=$(printf '%s' "$ALL_REFLECTIONS" | jq -r '[.[] | .note // empty | select(. != "")] | unique | .[]')
  if [ -n "$NOTES" ]; then
    echo ""
    echo "### Notes"
    # Print each note as a markdown bullet. The trailing `|| :` makes the branch
    # always succeed (`:` is the no-op true) so `set -e` can't abort on a blank line.
    while IFS= read -r item; do
      [ -n "$item" ] && echo "- $item" || :
    done <<< "$NOTES"
  fi

  # Flagged session suggestions: the "what to do better" notes from flagged sessions.
  FLAGGED_SUGGESTIONS=$(printf '%s' "$PARSED_SESSIONS" | jq -r '
    [.[] | select(.flagged) | select(.suggestion != null) | .suggestion] | unique | .[]
  ')
  if [ -n "$FLAGGED_SUGGESTIONS" ]; then
    echo ""
    echo "### Could Improve"
    while IFS= read -r item; do
      [ -n "$item" ] && echo "- $item" || :
    done <<< "$FLAGGED_SUGGESTIONS"
  fi

  # Week totals from sessions. get_day_totals (from session-utils.sh) returns a
  # JSON object; we read total_minutes / total_cost out of it.
  TOTALS=$(get_day_totals "$WEEK_SESSIONS")
  TOTAL_MIN=$(printf '%s' "$TOTALS" | jq '.total_minutes')
  TOTAL_COST=$(printf '%s' "$TOTALS" | jq '.total_cost')
  FLAGGED_COUNT=$(printf '%s' "$WEEK_SESSIONS" | jq '[.[] | select((.Flagged == 1 or .Flagged == true))] | length')
  if [ "$TOTAL_MIN" -gt 0 ]; then
    echo ""
    # `\$` escapes the dollar sign so bash prints a literal $ before the cost.
    echo "_Week totals: ${SESSION_COUNT} sessions, ${TOTAL_MIN}m, \$${TOTAL_COST}, ${FLAGGED_COUNT} flagged_"
  fi

} > "$OUT_FILE"   # <- redirect the whole brace group's output into the markdown file

# I18N_WEEKLY_WRITTEN is a printf format string (contains %s) → filename fills the %s.
printf "$I18N_WEEKLY_WRITTEN\n" "$OUT_FILE"

# [update-readme] -------------------------------------------------------------
# --- Update README.md ---
README="$DATA_README"
LINK_TEXT="from $MON_DISPLAY to $FRI_DISPLAY"
LINK_PATH="${YEAR}/${MONTH_NUM}-${MONTH_ABBR_LOWER}/${YEAR}_${MON_MM_DD}_${FRI_MM_DD}.md"

# Only add a link if README doesn't already reference this file. `grep -qF`:
# -q quiet (exit status only), -F fixed string (no regex). `!` negates the test.
if ! grep -qF "$LINK_PATH" "$README"; then
  # Build a per-month section header like "### 2026 Feb.". The `sed 's/./\U&/'`
  # uppercases the first character of the month abbreviation (\U = uppercase).
  SECTION_HEADER="### $YEAR $(echo "$MONTH_ABBR" | sed 's/./\U&/')."

  if grep -qF "$SECTION_HEADER" "$README"; then
    # Header exists → `sed ... /a TEXT` appends the bullet on the line AFTER it.
    sed -i "/$SECTION_HEADER/a * [$LINK_TEXT]($LINK_PATH)" "$README"
  else
    # No header yet → insert it (plus the bullet) right after the "## Logs" line.
    # The `\\n` sequences become newlines in the inserted text.
    sed -i "/^## Logs$/a \\\\n$SECTION_HEADER\\n* [$LINK_TEXT]($LINK_PATH)" "$README"
  fi
  echo "README.md updated with new entry"
fi

# [auto-commit] ---------------------------------------------------------------
# --- Auto-commit (only when the data dir is a git repo) ---
cd "$DATA_DIR"
if git -C "$DATA_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git add "$OUT_FILE" "$README"
  # Commit, but never let a failure (e.g. nothing to commit) abort the script:
  # --quiet hushes output; `|| true` swallows a non-zero exit.
  git commit -m "log: weekly summary for $MONDAY to $FRIDAY" --quiet 2>/dev/null || true
  echo "$I18N_WEEKLY_COMMITTED"
else
  echo "data dir is not a git repo — summary written, skipping commit"
fi
