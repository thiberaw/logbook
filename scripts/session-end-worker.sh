#!/usr/bin/env bash
# =============================================================================
# session-end-worker.sh — session analysis worker  [BACKGROUND WORKER]
#
# WHAT IT IS:  The heavy-lifting process that session-end.sh forks into the
#              background. It can run for many seconds (transcript parsing +
#              two LLM calls), which is why it must NOT run inline in the hook.
# ITS JOB:     Turn one finished Claude Code session into a database record:
#              compute duration, pull metrics from the transcript, write a
#              human-readable narrative, decide if the session is worth
#              flagging for review, and persist all of it to SQLite.
# INPUT:       command-line args (NOT stdin): $1=session_id $2=transcript_path
#              $3=cwd
# IT CALLS:    lib/transcript-analyzer.py  (Python; extracts metrics + condensed
#                                           transcript + first prompt)
#              lib/session-utils.sh        (derive_project_name, find_sessions_index,
#                                           narrative_extract_json/strip_json)
#              lib/sessions-db.sh          (all db_* SQLite helpers)
#              lib/fetch-articles.sh       (refreshes the article-suggestion cache)
#              claude (the CLI itself)     (haiku narrative + sonnet flag analysis)
#
# HOW TO READ THIS FILE — runs top to bottom, in these sections:
#   [setup]            strict mode + load libraries + read args
#   [duration]         work out how long the session lasted
#   [project]          derive a project name from the working directory
#   [metadata]         pull summary / first prompt / branch from the index
#   [skill detect]     figure out which slash-command/skill was used
#   [effective skill]  reconcile DB-tracked skill vs transcript-derived skill
#   [commits]          list git commits the session produced
#   [empty guard]      drop sessions with no real interaction
#   [metrics]          parse numeric metrics out of the transcript
#   [session name]     build the human-readable session title
#   [flag detection]   cheap heuristics that mark a session for review
#   [condensed]        shrink the transcript for feeding to the LLMs
#   [narrative]        haiku LLM writes the 5-section markdown narrative
#   [flag analysis]    sonnet LLM double-checks flagged sessions
#   [sqlite write]     persist everything to the database
#   [active json]      mirror results into active-session.json
#   [articles cache]   occasionally refresh article suggestions
#   [cleanup]          remove this session's start-tracking entry
# =============================================================================
# Session-end worker: runs in background after the hook exits.
# Extracts transcript metrics, generates LLM narrative, detects flags,
# and writes everything to SQLite.
# Args: $1=session_id $2=transcript_path $3=cwd
set -euo pipefail   # Strict mode. -e: abort on first failing command.
                    # -u: unset variable = error.  -o pipefail: any failing
                    # stage fails the whole pipeline.

# [setup] ---------------------------------------------------------------------
# Resolve THIS script's folder (BASH_SOURCE[0] = path to this file) so sourcing
# works from any cwd, then load the shared helper libraries.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"             # paths + env vars (STATE_DIR, GIT_USER, …)
source "$SCRIPT_DIR/lib/logging.sh"        # log_info / log_warn / log_error
source "$SCRIPT_DIR/lib/sessions-db.sh"    # db_* SQLite helpers
source "$SCRIPT_DIR/lib/session-utils.sh"  # derive_project_name, narrative_* etc.
source "$SCRIPT_DIR/lib/flag-analysis.sh"  # build_flag_prompt / extract_flag_json
source "$SCRIPT_DIR/lib/narrative-check.sh" # validate_narrative (confabulation check)
source "$SCRIPT_DIR/lib/pii-scrub.sh"      # scrub_pii — applied to everything we record

# Runtime state files (under config.sh's $STATE_DIR).
STATE_FILE="$STATE_DIR/session-starts.json"   # records when each session began
ACTIVE_FILE="$STATE_DIR/active-session.json"  # snapshot of the live session

# Under `set -e` an unexpected failure kills this background worker silently —
# the session row then stays an empty stub and gets pruned, erasing the session
# (this is how the flagged $76 session vanished on 2026-06-09). Log the abort
# point so any future death leaves a trace in logbook.log.
trap 'log_error "worker aborted at line $LINENO (exit=$?) session=${SESSION_ID:-?}"' ERR

# Positional args passed by session-end.sh (NOT stdin here).
SESSION_ID="$1"
TRANSCRIPT_PATH="$2"
CWD="$3"

# Bail if no session ID
[ -z "$SESSION_ID" ] && exit 0   # `-z` = empty string → nothing to analyze.

log_info "started session=$SESSION_ID"

# [duration] ------------------------------------------------------------------
# --- Duration calculation ---
STARTED_AT=""
if [ -f "$STATE_FILE" ]; then
  # `--arg sid X` injects the id as a jq variable; `.[$sid].started_at` reads
  # that session's stored start time. `// empty` → nothing if absent.
  STARTED_AT=$(jq -r --arg sid "$SESSION_ID" '.[$sid].started_at // empty' "$STATE_FILE")
fi
# If we never recorded a start, assume "now" (duration will come out as 0).
[ -z "$STARTED_AT" ] && STARTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# End time = right now, in UTC ISO-8601 (e.g. 2026-06-04T12:34:56Z).
ENDED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Convert both timestamps to Unix epoch seconds. `date -d STR +%s` parses STR;
# `2>/dev/null || echo 0` swallows parse errors and falls back to 0.
START_EPOCH=$(date -d "$STARTED_AT" +%s 2>/dev/null || echo 0)
END_EPOCH=$(date -d "$ENDED_AT" +%s 2>/dev/null || echo 0)
DURATION_MINUTES=$(( (END_EPOCH - START_EPOCH) / 60 ))   # $(( )) = integer math
[ "$DURATION_MINUTES" -lt 0 ] && DURATION_MINUTES=0      # never report negative

# [project] -------------------------------------------------------------------
# --- Derive project name ---
PROJECT_NAME=""
if [ -n "$CWD" ]; then   # `-n` = non-empty string
  PROJECT_NAME=$(derive_project_name "$CWD")   # helper from session-utils.sh
fi

log_info "duration=${DURATION_MINUTES}m project=${PROJECT_NAME}"

# [metadata] ------------------------------------------------------------------
# --- Extract session metadata from sessions-index.json ---
SUMMARY=""
FIRST_PROMPT=""
GIT_BRANCH=""

if [ -n "$CWD" ]; then
  SESSIONS_INDEX=$(find_sessions_index "$CWD")   # locate Claude's index json
  if [ -n "$SESSIONS_INDEX" ] && [ -f "$SESSIONS_INDEX" ]; then
    # `.entries[]?` iterates the entries array (the `?` avoids erroring if it's
    # missing); `select(.sessionId == $sid)` keeps only our session's object.
    SESSION_DATA=$(jq -r --arg sid "$SESSION_ID" '
      .entries[]? | select(.sessionId == $sid)
    ' "$SESSIONS_INDEX" 2>/dev/null || echo "")

    if [ -n "$SESSION_DATA" ]; then
      # Pull individual fields out of the matched JSON object.
      SUMMARY=$(echo "$SESSION_DATA" | jq -r '.summary // empty')
      FIRST_PROMPT=$(echo "$SESSION_DATA" | jq -r '.firstPrompt // empty')
      GIT_BRANCH=$(echo "$SESSION_DATA" | jq -r '.gitBranch // empty')

      # Fallback duration from sessions-index timestamps
      # Only if the hook-based duration above came out as 0 or less.
      if [ "$DURATION_MINUTES" -le 0 ]; then
        IDX_CREATED=$(echo "$SESSION_DATA" | jq -r '.created // empty')
        IDX_MODIFIED=$(echo "$SESSION_DATA" | jq -r '.modified // empty')
        if [ -n "$IDX_CREATED" ] && [ -n "$IDX_MODIFIED" ]; then
          # Try GNU `date -d` first; fall back to BSD/macOS `date -j -f FMT`.
          # `${IDX_CREATED%%.*}` strips any ".123456" fractional-seconds tail.
          IDX_START=$(date -d "$IDX_CREATED" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${IDX_CREATED%%.*}" +%s 2>/dev/null || echo 0)
          IDX_END=$(date -d "$IDX_MODIFIED" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${IDX_MODIFIED%%.*}" +%s 2>/dev/null || echo 0)
          IDX_DUR=$(( (IDX_END - IDX_START) / 60 ))
          [ "$IDX_DUR" -gt 0 ] && DURATION_MINUTES=$IDX_DUR
        fi
      fi
    fi
  fi
fi

# Fallback: parse transcript for first prompt
# If the index didn't give us a first prompt, ask the Python analyzer for it.
if [ -z "$FIRST_PROMPT" ] && [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  ERR_TMP=$(mktemp)   # temp file to capture the analyzer's stderr separately
  FIRST_PROMPT=$(python3 "$SCRIPT_DIR/lib/transcript-analyzer.py" --first-prompt "$TRANSCRIPT_PATH" 2>"$ERR_TMP" || echo "")
  # `-s` = file exists AND is non-empty → the analyzer printed an error; log it.
  [ -s "$ERR_TMP" ] && log_warn "transcript-analyzer --first-prompt: $(cat "$ERR_TMP")"
  rm -f "$ERR_TMP"
fi

# [skill detect] --------------------------------------------------------------
# Scrub PII from the raw prompt BEFORE anything derives from it (the session
# name/title and the first_prompt column both inherit this). User prompts
# routinely carry customer ticket URLs, names, and emails (2026-06-12 scrub).
if [ -n "$FIRST_PROMPT" ]; then
  FIRST_PROMPT=$(printf '%s' "$FIRST_PROMPT" | scrub_pii)
fi

# Detect skill invocation. FIRST_PROMPT is one of two shapes:
#   - readable slash-command form "/review-pr <args>" (transcript-analyzer's
#     parse_slash_command, added 2026-06-02) — the common case now;
#   - legacy skill-body injection "Base directory for this skill: ... # /review-pr — ".
# Match both. (The 2026-06-02 change to surface slash commands silently broke the
# legacy-only detection, bypassing the read-only-skill exemptions below and
# re-flagging /review-pr sessions on no-output/thrashing — see open-concerns.)
SKILL_NAME=""
# `[[ "$x" == /* ]]` = does the string start with a slash? (glob match, not regex)
if [[ "$FIRST_PROMPT" == /* ]]; then
  # grep -oP = print only the Perl-regex match; `\K` drops everything matched
  # before it, so `^/\K[a-z][-a-z:]+` yields just the command name after the "/".
  # `head -1` keeps the first match; `|| true` stops a no-match from failing -e.
  SKILL_NAME=$(echo "$FIRST_PROMPT" | grep -oP '^/\K[a-z][-a-z:]+' | head -1 || true)
elif [[ "$FIRST_PROMPT" == "Base directory for this skill:"* ]]; then
  # Legacy shape: skill name appears after "# /" inside an injected skill body.
  SKILL_NAME=$(echo "$FIRST_PROMPT" | grep -oP '# /\K[a-z][-a-z:]+' | head -1 || true)
fi

# [effective skill] -----------------------------------------------------------
# Resolve the effective skill for flagging decisions. Prefer the value the live
# SessionStart tracking already wrote to the DB `skill` column; fall back to the
# transcript-derived SKILL_NAME when tracking didn't fire (it is Claude-dependent
# and can be empty — e.g. #2434). Keying the read-only-skill exemptions off this
# combined value makes them robust to BOTH failure modes seen on 2026-06-04:
# FIRST_PROMPT-format changes that broke derivation, and missing live-tracking
# writes that left the column empty.
# `db_get_field` reads the skill column the live SessionStart tracking may have
# already written; `|| true` keeps -e happy if the row/field is missing.
DB_SKILL=$(db_get_field "$SESSION_ID" "skill" || true)
# `${DB_SKILL:-$SKILL_NAME}` = use the DB value, but fall back to the
# transcript-derived name when the DB value is empty. This makes the read-only
# skill exemptions below robust to BOTH failure modes: a missing live-tracking
# write AND a first-prompt format change that broke transcript derivation.
EFFECTIVE_SKILL="${DB_SKILL:-$SKILL_NAME}"

# [commits] -------------------------------------------------------------------
# Link commits produced during this session
COMMITS_PRODUCED="[]"   # default: empty JSON array
if [ -n "$CWD" ] && [ -n "$STARTED_AT" ] && [ -n "$ENDED_AT" ]; then
  # `rev-parse --git-dir` succeeds only inside a git repo; use it as the test.
  GIT_DIR=$(git -C "$CWD" rev-parse --git-dir 2>/dev/null || true)
  if [ -n "$GIT_DIR" ]; then
    # List this user's commits made during the session window and format each
    # as a JSON object via --pretty; `jq -s '.'` slurps those lines into one
    # JSON array. `|| echo "[]"` guards against any failure leaving it unset.
    COMMITS_PRODUCED=$(git -C "$CWD" log --all \
      --author="$GIT_USER" \
      --since="$STARTED_AT" \
      --until="$ENDED_AT" \
      --pretty=format:'{"hash":"%h","message":"%s"}' \
      2>/dev/null | jq -s '.' 2>/dev/null || echo "[]")
  fi
fi

# [empty guard] ---------------------------------------------------------------
# Skip sessions with no interaction
# No first prompt AND no summary → nothing happened; delete the stub row.
if [ -z "$FIRST_PROMPT" ] && [ -z "$SUMMARY" ]; then
  init_sessions_db
  log_info "no interaction — removing empty session"
  db_delete_session "$SESSION_ID"
  # Clean up
  if [ -f "$STATE_FILE" ]; then
    TMP=$(mktemp)
    # `del(.[$sid])` removes this session's key from the start-tracking JSON;
    # write to a temp file then `mv` over the original (atomic replace).
    jq --arg sid "$SESSION_ID" 'del(.[$sid])' "$STATE_FILE" > "$TMP" && mv "$TMP" "$STATE_FILE"
  fi
  exit 0
fi

# [metrics] -------------------------------------------------------------------
# --- Extract transcript metrics ---
log_info "extracting transcript metrics"
METRICS="{}"   # default: empty JSON object
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  ERR_TMP=$(mktemp)
  # The analyzer prints a JSON metrics blob on stdout; fall back to {} on error.
  METRICS=$(python3 "$SCRIPT_DIR/lib/transcript-analyzer.py" "$TRANSCRIPT_PATH" 2>"$ERR_TMP" || echo "{}")
  [ -s "$ERR_TMP" ] && log_warn "transcript-analyzer: $(cat "$ERR_TMP")"
  rm -f "$ERR_TMP"
  # Validate it really is JSON; if `jq .` can't parse it, reset to {}.
  echo "$METRICS" | jq . >/dev/null 2>&1 || { log_error "transcript-analyzer returned invalid JSON"; METRICS="{}"; }
fi

# Backfill duration from transcript timestamps if hook-based duration is 0
if [ "$DURATION_MINUTES" -le 0 ] && [ "$METRICS" != "{}" ]; then
  FIRST_TS=$(echo "$METRICS" | jq -r '.first_timestamp // empty')
  LAST_TS=$(echo "$METRICS" | jq -r '.last_timestamp // empty')
  if [ -n "$FIRST_TS" ] && [ -n "$LAST_TS" ]; then
    # `${FIRST_TS%%.*}Z` trims fractional seconds and re-appends the Z (UTC).
    TS_START=$(date -d "${FIRST_TS%%.*}Z" +%s 2>/dev/null || echo 0)
    TS_END=$(date -d "${LAST_TS%%.*}Z" +%s 2>/dev/null || echo 0)
    TS_DUR=$(( (TS_END - TS_START) / 60 ))
    [ "$TS_DUR" -gt 0 ] && DURATION_MINUTES=$TS_DUR
  fi
fi

# Backfill git branch from transcript if empty
if [ -z "$GIT_BRANCH" ] && [ "$METRICS" != "{}" ]; then
  GIT_BRANCH=$(echo "$METRICS" | jq -r '.git_branch // empty')
fi

# --- Extract numeric metrics ---
# Each `jq '.field // 0'` pulls a number out of METRICS, defaulting to 0.
COST_USD=$(echo "$METRICS" | jq '.cost_usd // 0')
TOTAL_TURNS=$(echo "$METRICS" | jq '.total_turns // 0')
TOTAL_TOOL_CALLS=$(echo "$METRICS" | jq '.total_tool_calls // 0')
TOOL_ERRORS_COUNT=$(echo "$METRICS" | jq '.tool_errors // 0')
FILES_MODIFIED_COUNT=$(echo "$METRICS" | jq '.files_modified_count // 0')
COMMIT_COUNT=$(echo "$COMMITS_PRODUCED" | jq 'length')   # length of the commits array

log_info "metrics: turns=${TOTAL_TURNS} tools=${TOTAL_TOOL_CALLS} errors=${TOOL_ERRORS_COUNT} files=${FILES_MODIFIED_COUNT} cost=${COST_USD}"

# [session name] --------------------------------------------------------------
# --- Build session name ---
TITLE_DESC=""
# Prefer the index's summary; otherwise distill a title from the first prompt.
if [ -n "$SUMMARY" ]; then
  TITLE_DESC="$SUMMARY"
elif [ -n "$FIRST_PROMPT" ]; then
  # `python3 -c "..."` runs the inline script below, reading the prompt on stdin.
  # It recognizes common prompt shapes (plans, skills, code reviews, errors) and
  # turns each into a short, tidy title; otherwise it truncates to ~80 chars.
  TITLE_DESC=$(echo "$FIRST_PROMPT" | python3 -c "
import sys, re
p = sys.stdin.read().replace('\n', ' ').strip()
p = re.sub(r'  +', ' ', p)
if re.search(r'Implement the following plan:.*# ', p):
    m = re.search(r'# ([^#\n]+)', p)
    p = 'Plan: ' + m.group(1).strip() if m else p[:80]
elif '# Plan: ' in p:
    m = re.search(r'# Plan: ([^#]+)', p)
    p = 'Plan: ' + m.group(1).strip() if m else p[:80]
elif re.search(r'Base directory for this skill:.*# /', p):
    m = re.search(r'# (/[a-z][-a-z]*)', p)
    p = m.group(1) if m else p[:80]
elif re.search(r'^# /[a-z]', p):
    m = re.search(r'# (/[a-z][-a-z]*)', p)
    p = m.group(1) if m else p[:80]
elif p.startswith('Provide a code review'):
    p = 'Code review'
elif re.match(r'^(Here.s a diff|diff --git|@@)', p):
    p = 'Diff review'
elif re.match(r'^(Error|Building .* Error|Cannot read|TypeError|ReferenceError)', p):
    p = 'Error investigation'
elif p.startswith('Read and understand'):
    p = 'Code analysis'
elif len(p) > 80:
    p = p[:80].rsplit(' ', 1)[0]
print(p)
" 2>/dev/null || printf '%s' "${FIRST_PROMPT:0:80}")
fi
[ -z "$TITLE_DESC" ] && TITLE_DESC="session"   # never leave the title blank

# Final display name, e.g. "[my-app] Fix flag heuristic (12m, $0.34)".
SESSION_NAME="[${PROJECT_NAME}] ${TITLE_DESC} (${DURATION_MINUTES}m, \$${COST_USD})"

# [flag detection] ------------------------------------------------------------
# --- Flag detection ---
# These are CHEAP heuristics that mark a session as "worth a human glance".
# They are deliberately noisy; the sonnet step later can clear false positives.
FLAGGED=false
FLAG_REASONS=""

if [ "$METRICS" != "{}" ]; then
  # High error rate: >30% of tool calls errored, minimum 3 errors
  if [ "$TOOL_ERRORS_COUNT" -ge 3 ] && [ "$TOTAL_TOOL_CALLS" -gt 0 ]; then
    # awk does the float division bash can't; LC_ALL=C forces a "." decimal
    # point regardless of locale. printf "%.2f" rounds to 2 decimals.
    ERROR_RATE=$(LC_ALL=C awk "BEGIN {printf \"%.2f\", $TOOL_ERRORS_COUNT / $TOTAL_TOOL_CALLS}")
    # awk again to compare floats: prints "true" when the rate exceeds 0.30.
    IS_HIGH=$(LC_ALL=C awk "BEGIN {print ($ERROR_RATE > 0.3) ? \"true\" : \"false\"}")
    if [ "$IS_HIGH" = "true" ]; then
      FLAGGED=true
      FLAG_REASONS="high error rate (${TOOL_ERRORS_COUNT} errors / ${TOTAL_TOOL_CALLS} tool calls)"
    fi
  fi

  # Spinning wheels: 5+ turns but no files modified and no commits
  # Skip for read-only skills
  # `[[ x =~ ^(a|b)$ ]]` = regex test; true if EFFECTIVE_SKILL is one of these
  # read-only skills, which legitimately produce no file changes.
  if [[ "$EFFECTIVE_SKILL" =~ ^(review-pr|analyze-ticket|explain-changes|investigate-ci|investigate-ticket)$ ]]; then
    : # read-only skill — no output expected  (`:` is bash's no-op)
  elif [ "$TOTAL_TURNS" -ge 5 ] && [ "$FILES_MODIFIED_COUNT" -eq 0 ] && [ "$COMMIT_COUNT" -eq 0 ]; then
    FLAGGED=true
    # `${VAR:+$VAR; }` = if VAR is non-empty, expand to "VAR; ", else "". This
    # appends each reason with a "; " separator only when reasons already exist.
    FLAG_REASONS="${FLAG_REASONS:+$FLAG_REASONS; }no output (${TOTAL_TURNS} turns, 0 files, 0 commits)"
  fi

  # Tests failed
  # `// null` so a missing field stays distinct from an explicit false.
  TESTS_PASSED=$(echo "$METRICS" | jq '.tests_passed // null')
  if [ "$TESTS_PASSED" = "false" ]; then
    FLAGGED=true
    FLAG_REASONS="${FLAG_REASONS:+$FLAG_REASONS; }tests failed"
  fi

  # Thrashing: high turn count relative to output
  # Skip for read-only skills — PR reviews / ticket analyses legitimately run
  # many turns and produce 0 files; flagging them on turn count alone is the
  # false-positive source for /review-pr sessions (see open-concerns 2026-06-02).
  if [[ "$EFFECTIVE_SKILL" =~ ^(review-pr|analyze-ticket|explain-changes|investigate-ci|investigate-ticket)$ ]]; then
    : # read-only skill — high turn / low file count is expected
  elif [ "$TOTAL_TURNS" -ge 12 ] && [ "$FILES_MODIFIED_COUNT" -le 1 ]; then
    FLAGGED=true
    FLAG_REASONS="${FLAG_REASONS:+$FLAG_REASONS; }high effort, low output (${TOTAL_TURNS} turns, ${FILES_MODIFIED_COUNT} files)"
  fi

  # High cost: sessions over $15 are worth reviewing regardless
  # Convert dollars to integer cents (awk) so bash's integer `-ge` can compare.
  COST_INT=$(LC_ALL=C awk "BEGIN {printf \"%d\", $COST_USD * 100}")
  if [ "$COST_INT" -ge 1500 ]; then   # 1500 cents = $15.00
    FLAGGED=true
    FLAG_REASONS="${FLAG_REASONS:+$FLAG_REASONS; }high cost (\$${COST_USD})"
  fi

  # Skill-not-used: ticket reference in first prompt but no skill triggered
  if [ -z "$EFFECTIVE_SKILL" ] && [ -n "$FIRST_PROMPT" ]; then
    # grep -qiE: quiet (no output), case-insensitive, extended regex. Matches a
    # Jira browse URL OR a ticket key like "SUP-123". Used only as a yes/no test.
    if echo "$FIRST_PROMPT" | grep -qiE '(atlassian\.net/browse/|[A-Z]{2,}-[0-9]+)'; then
      FLAGGED=true
      FLAG_REASONS="${FLAG_REASONS:+$FLAG_REASONS; }ticket reference without skill"
    fi
  fi
fi

[ "$FLAGGED" = true ] && log_warn "flagged: ${FLAG_REASONS}"

# Remember the heuristic verdict BEFORE the LLM pass can clear it — written to
# the heuristic_flagged column so the morning-review calibration watchdog can
# compare "heuristic fires" vs "LLM confirms" over time (2026-06-12: a prompt
# change silently zeroed the confirm rate for a week with no aggregate signal).
HEURISTIC_FLAGGED_INT=0
[ "$FLAGGED" = true ] && HEURISTIC_FLAGGED_INT=1

# [condensed] -----------------------------------------------------------------
# --- Condensed transcript (used for both narrative and flag analysis) ---
CONDENSED=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  # Ask the analyzer for a trimmed-down transcript suitable for an LLM prompt.
  CONDENSED=$(python3 "$SCRIPT_DIR/lib/transcript-analyzer.py" --condensed "$TRANSCRIPT_PATH" 2>/dev/null || echo "")
  # Hard-cap at 15000 chars to bound the LLM prompt size/cost. Must be bash
  # substrings, NOT `printf | head -c`: under pipefail, head exiting early sends
  # printf a SIGPIPE that kills the whole worker (lost a flagged $76 session on
  # 2026-06-09 — exactly the big transcripts this cap exists for).
  # Head+tail sampling (2026-06-12): a first-15K-only cut meant long sessions
  # were judged by how they BEGAN — end-of-session friction (where abandonment
  # happens) was truncated away. Keep the first 9K + the last 6K instead.
  if [ ${#CONDENSED} -gt 15000 ]; then
    ELIDED=$(( ${#CONDENSED} - 15000 ))
    CONDENSED="${CONDENSED:0:9000}
[... ${ELIDED} chars of mid-session trace elided (sampled head+tail) ...]
${CONDENSED: -6000}"
  fi
fi

# [ground truth] Deterministic anchors the LLMs must not contradict (2026-06-17
# evidence-grounding review). The condensed trace is a lossy head+tail sample
# with no tool results, so the narrative confabulates — claims "nothing shipped"
# when commits exist, cites hashes that aren't real. Prepend the metrics-derived
# facts (commits with real hashes, file/error/test counts) so every claim is
# checkable against ground truth instead of reconstructed from a partial trace.
if [ -n "$CONDENSED" ]; then
  case "${TESTS_PASSED:-null}" in
    true)  TESTS_LABEL="passed" ;;
    false) TESTS_LABEL="FAILED" ;;
    *)     TESTS_LABEL="not detected" ;;
  esac
  GROUND_TRUTH="=== GROUND TRUTH (deterministic — do not contradict these) ===
Files modified: ${FILES_MODIFIED_COUNT} | Commits: ${COMMIT_COUNT} | Tool errors: ${TOOL_ERRORS_COUNT}/${TOTAL_TOOL_CALLS} | Tests: ${TESTS_LABEL}"
  if [ "$COMMIT_COUNT" -gt 0 ]; then
    GROUND_TRUTH="${GROUND_TRUTH}
Commits produced (use these exact hashes; do not invent others):
$(echo "$COMMITS_PRODUCED" | jq -r '.[] | "  \(.hash) \(.message)"')"
  fi
  CONDENSED="${GROUND_TRUTH}

${CONDENSED}"
fi

# [narrative] -----------------------------------------------------------------
# --- LLM narrative (runs for ALL sessions with a transcript) ---
# Model is parameterized (2026-06-17 review): the everyday narrative — the
# signal the user actually reads each morning — was on the cheapest model while
# the better model (sonnet) was reserved for the near-always-empty flag channel.
# Override with NARRATIVE_MODEL to A/B a stronger model on substantive sessions.
# Substantive sessions earn the stronger model; trivial ones stay cheap. The
# sonnet demo (2026-06-17) pinned root causes from the trace that haiku missed,
# but it's a per-session cost — so gate it: >=20 turns OR >=$5 estimated cost.
# An explicit NARRATIVE_MODEL in the environment overrides the gate (for A/B).
if [ -z "${NARRATIVE_MODEL:-}" ]; then
  COST_GE5=$(LC_ALL=C awk "BEGIN {print ($COST_USD >= 5) ? 1 : 0}")
  if [ "${TOTAL_TURNS:-0}" -ge 20 ] || [ "$COST_GE5" = "1" ]; then
    NARRATIVE_MODEL="claude-sonnet-4-6"
  else
    NARRATIVE_MODEL="claude-haiku-4-5-20251001"
  fi
fi
NARRATIVE=""
TASK_TYPE=""
OUTCOME=""
# META_COST accumulates what THIS pipeline spends analyzing the session (the
# narrative + flag-analysis calls below). Persisted to the meta_cost column so
# watch-metrics can report reflection overhead as a fraction of total spend.
META_COST=0
if [ -n "$CONDENSED" ]; then
  log_info "generating LLM narrative (${NARRATIVE_MODEL})"
  # Build the prompt. It is one big double-quoted string, so ${VARS} are
  # interpolated and \" / \$ are literal quote / dollar characters in the text.
  NARRATIVE_PROMPT="You are analyzing a Claude Code session transcript to produce a concise narrative for a developer's morning review.

Session: ${PROJECT_NAME} on branch ${GIT_BRANCH}, ${DURATION_MINUTES}min, \$${COST_USD}
Skill: ${EFFECTIVE_SKILL:-none}
Tool calls: ${TOTAL_TOOL_CALLS}, errors: ${TOOL_ERRORS_COUNT}, files modified: ${FILES_MODIFIED_COUNT}
Commits: ${COMMIT_COUNT}

Condensed transcript:
${CONDENSED}

Write a markdown analysis with exactly these 5 sections. Be specific — reference actual files, tools, and counts from the transcript.

## Goal
What was the user trying to accomplish? One sentence.

## Approach
What did Claude actually do? Narrate the key steps (not a tool-call list). Mention pivots, retries, or exploration spirals if any. 2-4 sentences.

## Outcome
What was achieved? Reference specific commits, files created/modified, or state \"nothing shipped\". 1-2 sentences.

## Friction
What went wrong or was inefficient? Mention specific errors, repeated reads, unnecessary exploration, or wasted cycles. If the session was smooth, say so in one line. 1-3 sentences.

## Improvement Signal
One concrete, actionable thing that could make similar sessions better next time. Ground it in what actually happened (cite the specific files/tools/turns), but frame the fix as a general, project-agnostic principle — a global workflow habit, a skill change, or a global rule — NOT a rule scoped to one project's CLAUDE.md. (Good: \"verify the redirect target resolves to a real route before writing a fix.\" Bad: \"add an iframe-navigation rule to one project's CLAUDE.md.\") Still avoid vague advice like \"be more careful\" — agnostic does not mean vague. 1-2 sentences. If the session was smooth and nothing actionable stands out, write exactly: None. (Do NOT invent a signal to fill the section — a forced suggestion is worse than none.)

Rules:
- Total output under 400 words.
- No preamble, no wrapping — start directly with ## Goal.
- If the session was trivial (< 3 tool calls), keep the entire output to 3-4 lines.
- NEVER include customer names, personal names, email addresses, or customer organization names — refer to them generically ('the customer', 'a user', 'the org'). Internal file paths, repo names, and ticket keys are fine. This text is committed to a git repository.

After the markdown sections, on a new line, output exactly one JSON line (no markdown fencing) with two fields:
{\"task_type\": \"<one of: review, bugfix, feature, investigation, refactor, config, other>\", \"outcome\": \"<one of: success, partial, abandoned, wrong_approach>\"}

Definitions:
- task_type: the primary activity — review (PR review, code review), bugfix (fixing a bug), feature (new functionality), investigation (exploring/diagnosing without code changes), refactor (restructuring existing code), config (CI/CD, settings, infra), other
- outcome: success (goal achieved), partial (some progress but not complete), abandoned (gave up or wrong direction), wrong_approach (completed but the approach was suboptimal)

The JSON line MUST be the very last line of output."

  ERR_TMP=$(mktemp)
  # Pipe the prompt into the Claude CLI. `--print` = one-shot, non-interactive.
  # LOGBOOK_ANALYZER=1 marks this nested run so session-end.sh skips it (no
  # infinite recursion). Uses the cheap haiku model for the narrative.
  # --output-format json wraps the reply in an envelope carrying .result (the
  # text) AND .total_cost_usd (what this call cost). We used to take plain stdout
  # and throw the cost away — that blindness is exactly what this change fixes.
  RAW_NARRATIVE=$(echo "$NARRATIVE_PROMPT" | LOGBOOK_ANALYZER=1 claude --print --output-format json --model "$NARRATIVE_MODEL" 2>"$ERR_TMP" || echo "")
  [ -s "$ERR_TMP" ] && log_error "haiku narrative failed: $(head -5 "$ERR_TMP")"
  rm -f "$ERR_TMP"

  # Parse the envelope. If it isn't valid JSON (CLI format drift), fall back to
  # the raw text and a 0 cost — degrade, never crash the worker (2026-06-26 lesson).
  if NARRATIVE=$(printf '%s' "$RAW_NARRATIVE" | jq -er '.result' 2>/dev/null); then
    NARR_COST=$(printf '%s' "$RAW_NARRATIVE" | jq -r '.total_cost_usd // 0' 2>/dev/null)
  else
    NARRATIVE="$RAW_NARRATIVE"; NARR_COST=0
  fi
  META_COST=$(LC_ALL=C awk "BEGIN {printf \"%.4f\", ${META_COST:-0} + ${NARR_COST:-0}}")

  # `wc -w` counts words just for the log line.
  [ -n "$NARRATIVE" ] && log_info "narrative generated ($(echo "$NARRATIVE" | wc -w) words)"

  # Extract structured fields from the trailing JSON object.
  # Handles bare JSON, fenced ```json blocks, and missing/malformed JSON.
  if [ -n "$NARRATIVE" ]; then
    # Helpers from session-utils.sh: one pulls the trailing JSON line out, the
    # other returns the narrative with that JSON line removed.
    JSON_LINE=$(narrative_extract_json "$NARRATIVE")
    if [ -n "$JSON_LINE" ]; then
      TASK_TYPE=$(echo "$JSON_LINE" | jq -r '.task_type // empty')
      OUTCOME=$(echo "$JSON_LINE" | jq -r '.outcome // empty')
    fi
    NARRATIVE=$(narrative_strip_json "$NARRATIVE")
  fi
fi

# [flag analysis] -------------------------------------------------------------
# --- LLM analysis for flagged sessions ---
# Only flagged sessions get this second, more expensive (sonnet) pass. Its job
# is to confirm or clear the cheap heuristic flag and explain real problems.
ANALYSIS_ISSUE=""
ANALYSIS_SUGGESTION=""

if [ "$FLAGGED" = true ] && [ -n "$CONDENSED" ]; then
  log_info "generating LLM flag analysis (sonnet)"
  # The prompt lives in lib/flag-analysis.sh — the single source shared with
  # scripts/tests/test-flag-analysis.sh. Edit it THERE, then run the golden
  # test (RUN_LLM_TESTS=1) before shipping any prompt change.
  FLAG_PROMPT=$(build_flag_prompt "$CONDENSED" "$FLAG_REASONS" "$PROJECT_NAME" "$GIT_BRANCH" \
    "$DURATION_MINUTES" "$COST_USD" "$TOTAL_TURNS" "$TOTAL_TOOL_CALLS" \
    "$TOOL_ERRORS_COUNT" "$FILES_MODIFIED_COUNT")

  ERR_TMP=$(mktemp)
  # Same one-shot CLI call, but with the more capable sonnet model
  # ($FLAG_ANALYSIS_MODEL — shared with the regression test via lib/flag-analysis.sh).
  RAW_ANALYSIS_ENVELOPE=$(echo "$FLAG_PROMPT" | LOGBOOK_ANALYZER=1 claude --print --output-format json --model "$FLAG_ANALYSIS_MODEL" 2>"$ERR_TMP" || echo "")
  [ -s "$ERR_TMP" ] && log_error "sonnet analysis failed: $(head -5 "$ERR_TMP")"
  rm -f "$ERR_TMP"

  # Unwrap the JSON envelope to the model's text (extract_flag_json runs on that,
  # exactly as before — the golden corpus contract is unchanged) and bank the cost.
  if RAW_ANALYSIS=$(printf '%s' "$RAW_ANALYSIS_ENVELOPE" | jq -er '.result' 2>/dev/null); then
    FLAG_COST=$(printf '%s' "$RAW_ANALYSIS_ENVELOPE" | jq -r '.total_cost_usd // 0' 2>/dev/null)
  else
    RAW_ANALYSIS="$RAW_ANALYSIS_ENVELOPE"; FLAG_COST=0
  fi
  META_COST=$(LC_ALL=C awk "BEGIN {printf \"%.4f\", ${META_COST:-0} + ${FLAG_COST:-0}}")

  if [ -n "$RAW_ANALYSIS" ]; then
    # extract_flag_json (lib/flag-analysis.sh) pulls the {...} verdict out of
    # possibly-chatty output — same extraction the regression test exercises.
    ANALYSIS_JSON=$(extract_flag_json "$RAW_ANALYSIS")
    # `jq empty` parses but prints nothing — used purely as a "is this valid JSON?" test.
    if printf '%s' "$ANALYSIS_JSON" | jq empty 2>/dev/null; then
      # Map an explicit JSON null to an empty string (easier to test in bash).
      ANALYSIS_ISSUE=$(printf '%s' "$ANALYSIS_JSON" | jq -r 'if .issue == null then "" else .issue end')
      ANALYSIS_SUGGESTION=$(printf '%s' "$ANALYSIS_JSON" | jq -r 'if .suggestion == null then "" else .suggestion end')
      # If LLM says not actually flagged, respect that
      # (the model returns a null issue when the heuristic flag was a false positive).
      if [ -z "$ANALYSIS_ISSUE" ]; then
        FLAGGED=false
      fi
    fi
  fi
fi

# [sqlite write] --------------------------------------------------------------
# --- Write everything to SQLite ---
log_info "writing to SQLite"

# Last line of defense before anything is recorded: scrub LLM outputs. The
# narrative and flag prompts already forbid customer PII, but prompt compliance
# is probabilistic — the deterministic scrub catches the slips (and the
# denylist catches known customer names no regex can recognize).
[ -n "$NARRATIVE" ] && NARRATIVE=$(printf '%s' "$NARRATIVE" | scrub_pii)
[ -n "$ANALYSIS_ISSUE" ] && ANALYSIS_ISSUE=$(printf '%s' "$ANALYSIS_ISSUE" | scrub_pii)
[ -n "$ANALYSIS_SUGGESTION" ] && ANALYSIS_SUGGESTION=$(printf '%s' "$ANALYSIS_SUGGESTION" | scrub_pii)
SESSION_NAME=$(printf '%s' "$SESSION_NAME" | scrub_pii)
# SQLite has no boolean type; store the flag as 1/0.
FLAGGED_INT=0
[ "$FLAGGED" = true ] && FLAGGED_INT=1

init_sessions_db   # create the DB/schema if it doesn't exist yet

# Update metrics  (all db_* helpers live in lib/sessions-db.sh and run sqlite3)
db_update_metrics "$SESSION_ID" "$DURATION_MINUTES" "$COST_USD" "$TOTAL_TURNS" \
  "$TOTAL_TOOL_CALLS" "$TOOL_ERRORS_COUNT" "$FILES_MODIFIED_COUNT" \
  "$FLAGGED_INT" "$ANALYSIS_ISSUE" "$ANALYSIS_SUGGESTION" "$FIRST_PROMPT"

# Pre-LLM heuristic verdict, for the calibration watchdog (fires vs confirms).
db_update_field "$SESSION_ID" "heuristic_flagged" "$HEURISTIC_FLAGGED_INT"

# The pipeline's own spend on this session (narrative + flag-analysis calls).
db_update_field "$SESSION_ID" "meta_cost" "$META_COST"

# Update name (the rich title built from transcript analysis)
db_update_field "$SESSION_ID" "name" "$SESSION_NAME"

# Update description (LLM narrative)
if [ -n "$NARRATIVE" ]; then
  db_update_description "$SESSION_ID" "$NARRATIVE"
fi

# Update branch and skill if we detected them
# (only overwrite the column when we actually have a value)
[ -n "$GIT_BRANCH" ] && db_update_field "$SESSION_ID" "branch" "$GIT_BRANCH"
[ -n "$EFFECTIVE_SKILL" ] && db_update_field "$SESSION_ID" "skill" "$EFFECTIVE_SKILL"

# Update task_type and outcome extracted from LLM narrative
[ -n "$TASK_TYPE" ] && db_update_field "$SESSION_ID" "task_type" "$TASK_TYPE"
[ -n "$OUTCOME" ] && db_update_field "$SESSION_ID" "outcome" "$OUTCOME"

# Cross-check the narrative against deterministic facts (2026-06-17). The
# narrative is haiku working from a lossy trace, so it confabulates — this
# marks contradictions (cited-but-nonexistent commits, "nothing shipped" with
# commits present, an "abandoned" verdict on a no-op session) so the review can
# treat a 'low' narrative with suspicion instead of trusting it blindly.
if [ -n "$NARRATIVE" ]; then
  KNOWN_HASHES=$(echo "$COMMITS_PRODUCED" | jq -r '.[].hash' 2>/dev/null | tr '\n' ' ')
  NARRATIVE_VERDICT=$(validate_narrative "$NARRATIVE" "$FILES_MODIFIED_COUNT" \
    "$COMMIT_COUNT" "${TESTS_PASSED:-null}" "$TOTAL_TURNS" "$TOTAL_TOOL_CALLS" \
    "$OUTCOME" "$KNOWN_HASHES" "${CWD:-.}")
  NARRATIVE_CONFIDENCE=$(printf '%s' "$NARRATIVE_VERDICT" | cut -f1)
  NARRATIVE_ISSUES=$(printf '%s' "$NARRATIVE_VERDICT" | cut -f2-)
  db_update_field "$SESSION_ID" "narrative_confidence" "$NARRATIVE_CONFIDENCE"
  [ "$NARRATIVE_CONFIDENCE" = "low" ] && {
    db_update_field "$SESSION_ID" "narrative_issues" "$NARRATIVE_ISSUES"
    log_warn "narrative low-confidence: ${NARRATIVE_ISSUES}"
  }
fi

# [active json] ---------------------------------------------------------------
# --- Write to active-session.json (for any downstream consumers) ---
if [ -f "$ACTIVE_FILE" ]; then
  TMP=$(mktemp)
  # Merge the results into the existing JSON. `--argjson` passes a value as raw
  # JSON (number/object/bool), `--arg` passes it as a string. `. + { … }` adds
  # the new fields to the current object; write to temp then `mv` (atomic).
  jq --argjson duration "$DURATION_MINUTES" \
     --argjson metrics "$METRICS" \
     --arg ended "$ENDED_AT" \
     --argjson flagged "$FLAGGED" \
     --arg issue "$ANALYSIS_ISSUE" \
     --arg suggestion "$ANALYSIS_SUGGESTION" '
    . + {
      ended_at: $ended,
      duration_minutes: $duration,
      metrics: $metrics,
      analysis: {
        flagged: $flagged,
        issue: (if $issue == "" then null else $issue end),
        suggestion: (if $suggestion == "" then null else $suggestion end)
      }
    }
  ' "$ACTIVE_FILE" > "$TMP" && mv "$TMP" "$ACTIVE_FILE"
fi

# [articles cache] ------------------------------------------------------------
# --- Refresh article suggestions cache (at most once per 12 hours) ---
ARTICLES_CACHE="$STATE_DIR/articles-cache.json"
# Refresh if the cache is missing OR older than 720 minutes (12h). `find -mmin
# +720` prints the file only when its mtime is older than that, so a non-empty
# result means "stale". Refresh runs detached: nohup + & in background, with
# `&>/dev/null` discarding both stdout and stderr.
if [ ! -f "$ARTICLES_CACHE" ] || [ "$(find "$ARTICLES_CACHE" -mmin +720 2>/dev/null)" ]; then
  nohup bash "$SCRIPT_DIR/lib/fetch-articles.sh" &>/dev/null &
fi

# [cleanup] -------------------------------------------------------------------
# --- Clean up session-start entry ---
# Remove this session's start-tracking record now that it's fully processed.
if [ -f "$STATE_FILE" ]; then
  TMP=$(mktemp)
  # `del(.[$sid])` drops this session's key; temp-file + mv = atomic replace.
  jq --arg sid "$SESSION_ID" 'del(.[$sid])' "$STATE_FILE" > "$TMP" && mv "$TMP" "$STATE_FILE"
fi

log_info "done — duration=${DURATION_MINUTES}m cost=\$${COST_USD} turns=${TOTAL_TURNS} flagged=${FLAGGED}"
