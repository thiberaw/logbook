#!/usr/bin/env bash
# =============================================================================
# daily-report.sh — daily activity report generator  [generates the reviewed/<date>.md report]
#
# WHAT IT IS: a runnable script. Called via `bash` by morning-review.sh, and can
#   also be run standalone to (re)generate one day's report.
# ITS JOB: turn one day's stored data into a human-readable Markdown report.
# INPUT (args: [DATE] [OUTPUT_DIR]): DATE = YYYY-MM-DD (default: today);
#   OUTPUT_DIR = where the .md is written (default: $REVIEWED_DIR).
# reads from: the SQLite session database (via sessions-db.sh helpers) for the
#   session list, and the daily JSON file ($DAILY_DIR/<date>.json) for
#   intention, reflection, releases, and suggested articles.
#
# HOW TO READ THIS FILE — sections (look for the "# [section] ----" dividers):
#   [args]                parse DATE / OUTPUT_DIR, derive file paths
#   [fetch sessions]      open the DB and pull this day's sessions
#   [sanitize URLs]       define a filter that scrubs private Jira links
#   [build header]        the report title line
#   [plan + reflection]   optional sections from the daily JSON
#   [sessions list]       one bullet per Claude Code session + day totals
#   [improvement signals] per-session actionable advice
#   [releases]            pinned Claude / Claude Code release notes
#   [suggested reading]   other recommended articles
#   The whole report body is built inside one { ... } group whose output is
#   piped through sanitize_atlassian_urls into the .md file (see bottom).
# =============================================================================
# Generate/regenerate the daily markdown report.
# Sessions are read from the local SQLite database.
# Non-session data (intention, reflection, PRs, articles) from daily JSON.
# Usage: bash scripts/lib/daily-report.sh [DATE] [OUTPUT_DIR]

set -euo pipefail   # Strict mode: -e abort on any error, -u unset var = error, -o pipefail = a failing command in a pipe fails the whole pipe.

# Resolve this script's parent dir (scripts/) so the source paths below work no
# matter where the script is invoked from. ${BASH_SOURCE[0]} = path to this file.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"               # shared config: DAILY_DIR, REVIEWED_DIR, STATE_DIR, etc.
source "$SCRIPT_DIR/lib/sessions-db.sh"      # provides init_sessions_db, db_query_sessions_for_date
source "$SCRIPT_DIR/lib/session-utils.sh"    # provides get_day_totals, render_improvement_signals_md

# --- [args] Arguments ----------------------------------------------------------
# ${1:-DEFAULT} = use positional arg $1 if given, otherwise fall back to DEFAULT.
REPORT_DATE="${1:-$(date +%Y-%m-%d)}"
OUTPUT_DIR="${2:-$REVIEWED_DIR}"

# Guard: never default today's report into reviewed/. A reviewed/<date>.md marks
# the day as reviewed, so morning-review skips it forever — on 2026-06-04 a
# mid-day run wrote reviewed/2026-06-04.md at 15:19 and the afternoon's 4
# sessions were never reviewed. Writing today into reviewed/ now requires
# passing the directory explicitly as $2; default invocations land in a
# preview dir instead.
if [ "$REPORT_DATE" = "$(date +%Y-%m-%d)" ] && [ -z "${2:-}" ]; then
  OUTPUT_DIR="$STATE_DIR/preview"
  echo "NOTE: $REPORT_DATE is today — writing preview to $OUTPUT_DIR/$REPORT_DATE.md (pass an output dir explicitly to override)" >&2
elif [ "$REPORT_DATE" = "$(date +%Y-%m-%d)" ] && [ "$OUTPUT_DIR" = "$REVIEWED_DIR" ]; then
  # Explicit today-into-reviewed/ is still suspicious: the day isn't over, and a
  # reviewed/<today>.md makes morning-review skip the day's later sessions forever.
  echo "WARNING: writing TODAY's report into reviewed/ — later sessions today will never be reviewed." >&2
fi

DAILY_FILE="$DAILY_DIR/$REPORT_DATE.json"    # the day's JSON metadata file
MD_FILE="$OUTPUT_DIR/$REPORT_DATE.md"        # the markdown file we will produce

# Guard: reviewed/<date>.md is immutable history (immutable by design). An
# unnoticed regeneration is how the 2026-06-10 "review decay" contamination
# stayed invisible — refuse to overwrite an existing reviewed report unless the
# caller opts in deliberately with LOGBOOK_ALLOW_REGEN=1.
if [ "$OUTPUT_DIR" = "$REVIEWED_DIR" ] && [ -f "$MD_FILE" ] && [ "${LOGBOOK_ALLOW_REGEN:-0}" != "1" ]; then
  echo "ERROR: $MD_FILE already exists — reviewed reports are immutable history. Set LOGBOOK_ALLOW_REGEN=1 to regenerate deliberately." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Format the date nicely (force English locale for GitHub readability).
# Tries GNU `date -d` first, then BSD/macOS `date -j -f`, then falls back to the
# raw date string. `|| ... || ...` runs the next form only if the previous failed.
DISPLAY_DATE=$(LC_ALL=en_US.UTF-8 date -d "$REPORT_DATE" +"%A, %B %-d %Y" 2>/dev/null \
  || LC_ALL=en_US.UTF-8 date -j -f "%Y-%m-%d" "$REPORT_DATE" +"%A, %B %-d %Y" 2>/dev/null \
  || echo "$REPORT_DATE")

# --- [fetch sessions] Pull this day's sessions from the local SQLite store -----
# Fetch sessions for this date from local store
init_sessions_db                                       # open / migrate the DB if needed
SESSIONS=$(db_query_sessions_for_date "$REPORT_DATE")  # JSON array of session rows

# --- [sanitize URLs + PII] -------------------------------------------------------
# Scrub customer-identifying data from the rendered markdown before it is
# committed. The repo is private today (verified 2026-06-12), but treat the
# committed file as potentially shareable: visibility is one setting away.
# Three layers: (1) the LLM prompts forbid customer names/emails/orgs at the
# source; (2) the worker scrubs everything at DB-write time; (3) this final
# render-time pass catches anything that still slipped through. All three use
# the same scrub_pii (lib/pii-scrub.sh): atlassian URLs collapse to ticket
# keys, emails -> <email>, org IDs -> <id>, plus the gitignored customer-name
# denylist ($STATE_DIR/pii-denylist.txt).
source "$SCRIPT_DIR/lib/pii-scrub.sh"

# Everything inside this { ... } block prints the report to stdout; the closing
# brace at the bottom pipes that stdout through sanitize_atlassian_urls > MD_FILE.
{
  # --- [build header] Report title ---------------------------------------------
  echo "# Dev Log — $DISPLAY_DATE"
  echo ""

  # --- [plan + reflection] Optional sections sourced from the daily JSON -------
  # Intention (plan for the day)
  if [ -f "$DAILY_FILE" ]; then
    # `jq -r '.intention // empty'` = read field .intention as raw text; if absent, emit nothing.
    INTENTION=$(jq -r '.intention // empty' "$DAILY_FILE")
    if [ -n "${INTENTION:-}" ]; then          # -n = non-empty string
      echo "## Plan"
      echo ""
      echo "$INTENTION"
      echo ""
    fi

    # Reflection
    # `jq -r '.reflection.note // empty'` = nested field; empty if missing. 2>/dev/null hides jq parse errors.
    REFLECTION_NOTE=$(jq -r '.reflection.note // empty' "$DAILY_FILE" 2>/dev/null)
    if [ -n "${REFLECTION_NOTE:-}" ]; then
      echo "## Reflection"
      echo ""
      echo "> $REFLECTION_NOTE"                # markdown blockquote
      echo ""
    fi
  fi

  # --- [sessions list] One bullet per Claude Code session, then day totals -----
  # Sessions (from SQLite)
  SESSION_COUNT=$(printf '%s' "$SESSIONS" | jq 'length')   # number of sessions in the JSON array
  if [ "$SESSION_COUNT" -gt 0 ]; then
    echo "## Claude Code Sessions"
    echo ""

    # Render each session as a line.
    # The jq program below binds several `as` aliases per session, then assembles
    # one markdown bullet (and an optional indented quote line when flagged):
    #   $flagged - true if .Flagged is set to a non-zero / non-false value
    #   $proj    - project name (fallback "unknown")
    #   $dur     - duration in minutes, as a string
    #   $cost    - .Cost rounded to 2 decimals (×100, round, /100)
    #   $turns   - number of turns
    #   $cpt     - cost-per-turn (Cost/turns) rounded to 2 dp; "" when no turns
    #   $desc    - description, falling back to .Name then "session"
    #   $skill   - skill name, or null
    # The bullet truncates long descriptions to 80 chars with an ellipsis, and
    # appends a `\`skill\`` tag only when a skill is present.
    printf '%s' "$SESSIONS" | jq -r '
      .[] |
      ((.Flagged // 0) != 0 and (.Flagged // 0) != false) as $flagged |
      (.Project // "unknown") as $proj |
      (.Duration // 0 | tostring) as $dur |
      (.Cost // 0 | . * 100 | round / 100 | tostring) as $cost |
      (.Turns // 0) as $turns |
      (if $turns > 0 then ((.Cost // 0) / $turns * 100 | round / 100 | tostring) else "" end) as $cpt |
      # The stored Description is a 5-section narrative (## Goal / ## Approach /
      # ## Outcome / ## Friction / ## Improvement Signal). The bullet wants only
      # the one-sentence Goal — slice it out the same way render_improvement_signals
      # slices ## Improvement Signal, else the raw heading + Approach text leaks into
      # the bullet and the 80-char truncator cuts mid-word (2026-06-15 reflection).
      (.Name // "session") as $name |
      (.Description // "") as $full |
      (if ($full | test("## Goal")) then
         ($full | split("## Goal")[1] | split("\n##")[0]
                | gsub("^\\s+|\\s+$"; "") | gsub("\\s*\\n\\s*"; " "))
       elif ($full != "") then $full
       else $name end) as $g |
      (if $g == "" then $name else $g end) as $desc |
      (.Skill // null) as $skill |
      # Outcome badge: only surface non-success outcomes (partial / abandoned /
      # wrong_approach). Rendering "success" on every bullet is noise; a
      # non-success badge is the signal that earns a second look (the #8251
      # spiral was recorded as "abandoned" but never shown — 2026-06-17 review).
      (.Outcome // "") as $outcome |
      (if ($outcome != "" and $outcome != "success") then " ⚠ _\($outcome)_" else "" end) as $badge |
      # Low-confidence narratives contradict the deterministic facts
      # (lib/narrative-check.sh) — mark them so the prose is not trusted blindly.
      (if (.Narrative_Confidence // "") == "low" then " ⚠ _unverified_" else "" end) as $unverified |
      "- **\($proj)** (\($dur)m, $\($cost)" + (if $cpt != "" then ", $\($cpt)/turn" else "" end) + ")" +
      " — \($desc | if length > 80 then .[:80] + "…" else . end)" +
      (if $skill != null and $skill != "" then " `\($skill)`" else "" end) + $badge + $unverified,
      # Flag line
      (if $flagged then
        "  > \(.Issue // "see details")"
       else empty end)
    '

    # Day totals (aggregate minutes / cost / avg cost-per-turn for the day).
    TOTALS=$(get_day_totals "$SESSIONS")
    TOTAL_MIN=$(printf '%s' "$TOTALS" | jq '.total_minutes')
    TOTAL_COST=$(printf '%s' "$TOTALS" | jq '.total_cost')
    # `jq -r '.avg_cost_per_turn // empty'` = the average, or nothing if not present.
    AVG_CPT=$(printf '%s' "$TOTALS" | jq -r '.avg_cost_per_turn // empty')
    # Print totals if there were any minutes, or any positive cost. `bc -l` does
    # the float comparison ("$TOTAL_COST > 0" -> 1/0); falls back to 0 if bc is missing.
    if [ "$TOTAL_MIN" -gt 0 ] || [ "$(echo "$TOTAL_COST > 0" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
      echo ""
      # Costs are token-count ESTIMATES priced from a model table (see
      # transcript-analyzer.py), not billed amounts — label them as such.
      if [ -n "$AVG_CPT" ] && [ "$AVG_CPT" != "null" ]; then
        # \$ keeps the dollar sign literal (not a shell variable). _..._ = markdown italics.
        echo "_Day totals: ${TOTAL_MIN}m, ~\$${TOTAL_COST} (est.), ~\$${AVG_CPT}/turn avg_"
      else
        echo "_Day totals: ${TOTAL_MIN}m, ~\$${TOTAL_COST} (est.)_"
      fi
    fi

    # Flag-rate line: makes a zero-flag day legible as a data state (nothing met
    # flag criteria) rather than a silent analysis failure (2026-06-10 reflection).
    FLAGGED_COUNT=$(printf '%s' "$SESSIONS" | jq '[.[] | select((.Flagged // 0) != 0 and (.Flagged // 0) != false)] | length')
    echo ""
    echo "_Flagged: ${FLAGGED_COUNT} of ${SESSION_COUNT} sessions_"

    # Outcome distribution: the per-session `outcome` label is recorded for every
    # session but was never surfaced (2026-06-17 review). One line makes "how did
    # the day go" legible — and names the non-success sessions explicitly.
    OUTCOMES=$(printf '%s' "$SESSIONS" | jq -r '
      [.[] | .Outcome // "" | select(. != "")] | group_by(.) |
      map("\(length) \(.[0])") | join(" · ")')
    if [ -n "$OUTCOMES" ]; then
      echo ""
      echo "_Outcomes: ${OUTCOMES}_"
    fi
    echo ""

    # --- [improvement signals] Per-session actionable advice -------------------
    # Improvement signals (per-session actionable advice)
    SIGNALS=$(render_improvement_signals_md "$SESSIONS")   # pre-rendered markdown, or empty
    if [ -n "$SIGNALS" ]; then
      echo "## Improvement Signals"
      echo ""
      echo "$SIGNALS"
      echo ""
    fi
  fi

  # PR data is kept in the daily JSON for personal review but never rendered
  # to the committed markdown — treat this file as potentially shareable.
  if [ -f "$DAILY_FILE" ]; then
    # --- [releases] Pinned Claude / Claude Code release notes (must-read) ------
    # Claude / Claude Code releases (pinned, must-read)
    # `jq '.claude_releases // [] | length'` = count entries; treat missing field as empty array.
    RELEASE_COUNT=$(jq '.claude_releases // [] | length' "$DAILY_FILE")
    if [ "$RELEASE_COUNT" -gt 0 ]; then
      echo "## Claude / Claude Code Releases"
      echo ""
      # For each release, emit "- [title](url)", optionally " — published date",
      # then a cleaned, truncated description. The gsub() chain scrubs the raw
      # feed text in this order:
      #   &#NN;        numeric HTML entities  -> space
      #   &name;       named HTML entities    -> space
      #   <...> / <..  HTML tags (incl. one left unclosed at end) -> removed
      #   \s+          runs of whitespace     -> single space
      #   ^ +| +$      leading/trailing space -> removed
      # Then: only keep descriptions longer than 10 chars; indent and cap at 200
      # chars (197 + "...").
      jq -r '.claude_releases[] |
        "- [\(.title)](\(.url))" +
        (if (.published // "") | length > 0 then " — \(.published)" else "" end) +
        ((.description // "")
          | gsub("&#[0-9]+;"; " ") | gsub("&[a-z]+;"; " ")
          | gsub("<[^>]*>"; "") | gsub("<[^>]*$"; "")
          | gsub("\\s+"; " ") | gsub("^ +| +$"; "")
          | if length > 10 then "\n  " + (if length > 200 then .[0:197] + "..." else . end) else "" end
        )
      ' "$DAILY_FILE"
      echo ""
    fi

    # --- [suggested reading] Other recommended articles -------------------------
    # Suggested reading (from daily JSON)
    ARTICLE_COUNT=$(jq '.suggested_articles // [] | length' "$DAILY_FILE")
    if [ "$ARTICLE_COUNT" -gt 0 ]; then
      echo "## Suggested Reading"
      echo ""
      # Same as releases above, plus an extra `gsub("submitted by.*"; "")` that
      # drops trailing "submitted by ..." boilerplate (common on aggregator
      # feeds). Description capped at 150 chars (147 + "...").
      jq -r '.suggested_articles[] |
        "- [\(.title)](\(.url))" +
        (if .stale == true then " _(previously shown)_" else "" end) +
        ((.description // "")
          | gsub("&#[0-9]+;"; " ") | gsub("&[a-z]+;"; " ")
          | gsub("submitted by.*"; "")
          | gsub("<[^>]*>"; "") | gsub("<[^>]*$"; "")
          | gsub("\\s+"; " ") | gsub("^ +| +$"; "")
          | if length > 10 then "\n  " + (if length > 150 then .[0:147] + "..." else . end) else "" end
        )
      ' "$DAILY_FILE"
      echo ""
    fi
  fi

# End of the report body. Pipe the whole accumulated stdout through the PII
# scrubber and write the result to the markdown file.
} | scrub_pii > "$MD_FILE"
