#!/usr/bin/env bash
# =============================================================================
# session-utils.sh — shared rendering & narrative helpers  [LIBRARY — sourced, not run]
#
# WHAT IT IS:  formatting helpers that turn the sessions JSON (from sessions-db.sh)
#              into human-readable output, plus two helpers for handling the
#              trailing JSON block the LLM appends to each narrative.
# SOURCED BY:  morning-review.sh, daily-report.sh, weekly-summary.sh,
#              and the narrative-strip test. Source config.sh
#              and sessions-db.sh first.
# PROVIDES:    get_day_totals                — sum a day's sessions → totals JSON
#              render_session_list           — number + format each session (one line)
#              render_improvement_signals    — print flagged issues/signals via gum (TUI)
#              render_improvement_signals_md — same, but as markdown for the report
#              narrative_extract_json        — pull the trailing {…"task_type"…} block out
#              narrative_strip_json          — return the narrative WITHOUT that block
#
# Most functions take the sessions JSON as $1 and pipe it through `jq`. In jq,
# `.X // default` means "field X, or this default if it's null/missing".
# =============================================================================

# get_day_totals — given the day's sessions JSON, print a small JSON object with
# the totals (count, minutes, cost, turns, avg cost/turn, flagged count).
get_day_totals() {
  local sessions_json="$1"
  printf '%s' "$sessions_json" | jq '
    ([.[] | .Turns // 0] | add // 0) as $total_turns |          # sum of all turns
    ([.[] | .Cost // 0] | add // 0) as $total_cost_raw |        # sum of all costs
    {
      session_count: length,
      total_minutes: ([.[] | .Duration // 0] | add // 0),
      total_cost: ($total_cost_raw * 100 | round / 100),        # round to 2 decimals
      total_turns: $total_turns,
      # avoid divide-by-zero: only compute the average when there are turns
      avg_cost_per_turn: (if $total_turns > 0 then ($total_cost_raw / $total_turns * 100 | round / 100) else null end),
      flagged_count: [.[] | select(.Flagged == 1 or .Flagged == true)] | length
    }
  '
}

# render_session_list — print one numbered line per session:
#   "  1. project (12m, $3.40) — description… [task_type → outcome]"
render_session_list() {
  local sessions_json="$1"
  # `to_entries[]` turns the array into {key,value} pairs so we get the index (.key).
  printf '%s' "$sessions_json" | jq -r '
    to_entries[] |
    .value as $s |
    ($s.Project // "unknown") as $proj |
    ($s.Duration // 0 | tostring) as $dur |
    ($s.Cost // 0 | . * 100 | round / 100 | tostring) as $cost |
    # The stored Description is a 5-section narrative (## Goal / ## Approach /
    # ## Outcome / ## Friction / ## Improvement Signal). Show only the one-line
    # ## Goal — dumping $s.Description raw leaks the "## Goal" heading and bleeds
    # into ## Approach when the goal is short (TUI counterpart of the daily-report
    # bullet extraction; 2026-06-22 review found this function never extracted).
    ($s.Description // "") as $full |
    (if ($full | test("## Goal")) then
       ($full | split("## Goal")[1] | split("\n##")[0]
              | gsub("^\\s+|\\s+$"; "") | gsub("\\s*\\n\\s*"; " "))
     elif ($full != "") then $full
     else ($s.Name // "session") end) as $desc |
    # optional " [task_type → outcome]" suffix, only when those fields are set
    (if (($s.Task_Type // "") != "") and (($s.Outcome // "") != "") then " [\($s.Task_Type) → \($s.Outcome)]" elif ($s.Task_Type // "") != "" then " [\($s.Task_Type)]" else "" end) as $classification |
    # Mark narratives that failed the deterministic cross-check (narrative-check.sh)
    # so the reviewer reads the prose with suspicion rather than trust.
    (if ($s.Narrative_Confidence // "") == "low" then " ⚠ unverified" else "" end) as $unverified |
    # .key+1 = 1-based number; truncate long descriptions to 80 chars with an ellipsis
    "  \(.key + 1). \($proj) (\($dur)m, $\($cost)) — \($desc | if length > 80 then .[:80] + "…" else . end)\($classification)\($unverified)"
  '
}

# render_improvement_signals — TUI version (uses `gum style` to print colored text).
# For each session it shows the flagged issue (+ suggestion) and/or the
# "## Improvement Signal" section pulled out of the description.
# A session is "noteworthy-bad" (renders ORANGE) when ANY deterministic quality
# signal is set — NOT only when the LLM `flagged` bit fires. This decouples the
# review's legibility from the flag pipeline: when flag confirmation collapsed to
# ~0% (2026-06-05..22) the orange branch went dark and the whole review read as a
# flat grey/green list (2026-06-22 review). The flag-independent signals are:
#   - Outcome in {partial, abandoned, wrong_approach}
#   - Narrative_Confidence == 'low'  (narrative contradicts the deterministic facts)
# plus the original flagged+issue path. The colour model is unchanged — grey
# baseline / orange warning / green recommendation — only the orange triggers grew.
render_improvement_signals() {
  local sessions_json="$1"
  local signals
  # `jq -c` = compact (one JSON object per line) so the `while read` loop below can
  # process them one at a time. This first pass extracts + derives the print fields.
  signals=$(printf '%s' "$sessions_json" | jq -c '
    .[] |
    (.Project // "unknown") as $proj |
    ((.Flagged // 0) != 0 and (.Flagged // 0) != false) as $flagged |
    (.Issue // "") as $issue |
    (.Suggestion // "") as $suggestion |
    (.Task_Type // "") as $ttype |
    (.Outcome // "") as $outcome |
    (.Turns // 0) as $turns |
    (.Tool_Calls // 0) as $calls |
    (.Narrative_Confidence // "") as $nconf |
    (.Narrative_Issues // "") as $nissues |
    (.Description // "") as $full |
    # one-line ## Goal sentence = the session description shown as context
    (if ($full | test("## Goal")) then
       ($full | split("## Goal")[1] | split("\n##")[0]
              | gsub("^\\s+|\\s+$"; "") | gsub("\\s*\\n\\s*"; " "))
     elif ($full != "") then $full
     else (.Name // "session") end) as $goal |
    # "## Improvement Signal" section → the green recommendation
    (if ($full | test("## Improvement Signal")) then
       ($full | split("## Improvement Signal")[1] | split("\n---")[0]
              | gsub("^\\s+|\\s+$"; "") | gsub("\\n+"; " "))
     else "" end) as $raw_signal |
    # Drop "None." / "N/A ..." placeholders — the narrative prompt allows an
    # explicit no-signal answer (2026-06-12) so clean sessions stop generating
    # forced advice; only real signals should reach the review.
    (if ($raw_signal | test("^(None|N/A)\\b"; "i")) then "" else $raw_signal end) as $signal |
    # A 0-turn/0-call session attempted nothing (e.g. open-then-/exit). Its
    # recorded outcome ("abandoned") and any low narrative confidence are the
    # cosmetic no-op shape, not real friction — never paint these orange
    # (mirrors narrative-check rule 4; 2026-06-22 review).
    (($turns == 0) and ($calls == 0)) as $noop |
    # noteworthy-bad set (flag-independent)
    (($outcome == "partial") or ($outcome == "abandoned") or ($outcome == "wrong_approach")) as $bad_outcome |
    ($nconf == "low") as $low_conf |
    (($noop | not) and (($flagged and $issue != "") or $bad_outcome or $low_conf)) as $bad |
    # the orange warning line — most specific source wins
    (if ($flagged and $issue != "") then $issue
     elif $bad_outcome then "outcome: \($outcome)"
     elif $low_conf then ("unverified" + (if $nissues != "" then " — \($nissues)" else "" end))
     else "" end) as $warn |
    # keep sessions that carry a recommendation OR a real warning
    select($signal != "" or $bad) |
    {proj: $proj, ttype: $ttype, outcome: $outcome, bad: $bad, warn: $warn,
     suggestion: $suggestion, signal: $signal, goal: $goal}
  ')

  [ -z "$signals" ] && return 0   # nothing to show

  # Loop over each compact JSON line. `IFS= read -r` reads a raw line unmodified.
  printf '%s\n' "$signals" | while IFS= read -r entry; do
    local proj ttype outcome bad warn suggestion signal goal classification
    proj=$(printf '%s' "$entry" | jq -r '.proj')
    ttype=$(printf '%s' "$entry" | jq -r '.ttype')
    outcome=$(printf '%s' "$entry" | jq -r '.outcome')
    bad=$(printf '%s' "$entry" | jq -r '.bad')
    warn=$(printf '%s' "$entry" | jq -r '.warn')
    suggestion=$(printf '%s' "$entry" | jq -r '.suggestion')
    signal=$(printf '%s' "$entry" | jq -r '.signal')
    goal=$(printf '%s' "$entry" | jq -r '.goal')

    # optional " [task_type → outcome]" suffix on the header
    classification=""
    if [ -n "$ttype" ] && [ -n "$outcome" ]; then
      classification=" [$ttype → $outcome]"
    elif [ -n "$ttype" ]; then
      classification=" [$ttype]"
    fi

    # Header (title): ORANGE(214) ⚠ when noteworthy-bad, else GREY(245). The
    # baseline stays grey so a clean day isn't all-green (2026-06-18 reflection).
    if [ "$bad" = "true" ]; then
      gum style --foreground 214 --bold "  ⚠ $proj$classification"
    else
      gum style --foreground 245 --bold "  $proj$classification"
    fi

    # Description context line (GREY) — the ## Goal sentence, truncated.
    if [ -n "$goal" ]; then
      [ ${#goal} -gt 200 ] && goal="${goal:0:200}…"
      gum style --foreground 245 "    $goal"
    fi

    # Warning line (ORANGE) — only when noteworthy-bad.
    if [ "$bad" = "true" ] && [ -n "$warn" ]; then
      gum style --foreground 214 "    $warn"
    fi

    # Recommendation lines (GREEN): the flag-analysis suggestion (flagged only),
    # then the narrative's Improvement Signal. Both render green so zero-flag days
    # still show green advice against a grey header (2026-06-15/16 reflections).
    if [ -n "$suggestion" ]; then
      gum style --foreground 82 "    → $suggestion"
    fi
    if [ -n "$signal" ]; then
      gum style --foreground 82 "    → $signal"
    fi
    echo ""
  done
}

# render_improvement_signals_md — same selection + derivation as the TUI version,
# but emits Markdown bullets (for the committed reviewed/<date>.md report).
render_improvement_signals_md() {
  local sessions_json="$1"
  printf '%s' "$sessions_json" | jq -r '
    .[] |
    (.Project // "unknown") as $proj |
    ((.Flagged // 0) != 0 and (.Flagged // 0) != false) as $flagged |
    (.Issue // "") as $issue |
    (.Suggestion // "") as $suggestion |
    (.Task_Type // "") as $ttype |
    (.Outcome // "") as $outcome |
    (.Turns // 0) as $turns |
    (.Tool_Calls // 0) as $calls |
    (.Narrative_Confidence // "") as $nconf |
    (.Narrative_Issues // "") as $nissues |
    (.Description // "") as $full |
    (if ($full | test("## Goal")) then
       ($full | split("## Goal")[1] | split("\n##")[0]
              | gsub("^\\s+|\\s+$"; "") | gsub("\\s*\\n\\s*"; " "))
     elif ($full != "") then $full
     else (.Name // "session") end) as $goal |
    (if ($full | test("## Improvement Signal")) then
       ($full | split("## Improvement Signal")[1] | split("\n---")[0]
              | gsub("^\\s+|\\s+$"; ""))
     else "" end) as $raw_signal |
    (if ($raw_signal | test("^(None|N/A)\\b"; "i")) then "" else $raw_signal end) as $signal |
    (($turns == 0) and ($calls == 0)) as $noop |
    (($outcome == "partial") or ($outcome == "abandoned") or ($outcome == "wrong_approach")) as $bad_outcome |
    ($nconf == "low") as $low_conf |
    (($noop | not) and (($flagged and $issue != "") or $bad_outcome or $low_conf)) as $bad |
    (if ($flagged and $issue != "") then $issue
     elif $bad_outcome then "outcome: \($outcome)"
     elif $low_conf then ("unverified" + (if $nissues != "" then " — \($nissues)" else "" end))
     else "" end) as $warn |
    (if ($ttype != "" and $outcome != "") then " [\($ttype) → \($outcome)]" else "" end) as $class |
    select($signal != "" or $bad) |
    # "- **proj** [type → outcome] — goal" then nested ⚠ warning / → recommendations
    ("- **\($proj)**\($class) — \($goal)"
     + (if $bad and $warn != "" then "\n  - ⚠ \($warn)" else "" end)
     + (if $suggestion != "" then "\n  - → \($suggestion)" else "" end)
     + (if $signal != "" then "\n  - → \($signal)" else "" end))
  '
}

# narrative_extract_json — the LLM appends a JSON blob like {... "task_type" ...} to
# its narrative; this returns that blob (the LAST one if several). arg: the narrative.
# Handles both bare and fenced (```json ... ```) forms.
narrative_extract_json() {
  local narrative="$1"
  local candidate
  # grep -oE prints only the matched text; the regex matches a {...} containing
  # "task_type" with no nested braces; `tail -1` keeps the last match.
  candidate=$(printf '%s\n' "$narrative" | grep -oE '\{[^{}]*"task_type"[^{}]*\}' | tail -1)
  [ -z "$candidate" ] && return 0
  # `jq empty` validates it's well-formed JSON; only then echo it.
  echo "$candidate" | jq empty 2>/dev/null && echo "$candidate"
}

# narrative_strip_json — return the narrative with that trailing JSON block (and any
# wrapping ``` fence / trailing blank lines) removed, so we store clean prose.
# The awk buffers all lines, finds the last line containing "task_type", walks back
# over an opening fence, then prints everything before it (trimming trailing blanks).
# If no JSON block is found, it prints the input unchanged.
narrative_strip_json() {
  local narrative="$1"
  printf '%s\n' "$narrative" | awk '
    { lines[NR] = $0 }                              # buffer every line (NR = line number)
    END {
      last_json = 0
      for (i = NR; i >= 1; i--) {                   # search upward for the JSON line
        if (lines[i] ~ /"task_type"/) { last_json = i; break }
      }
      if (last_json == 0) {                         # no JSON block → print as-is
        for (i = 1; i <= NR; i++) print lines[i]
        exit
      }
      first = last_json
      if (first > 1 && lines[first-1] ~ /^[[:space:]]*```/) first = first - 1   # include opening fence
      for (i = last_json + 1; i <= NR; i++) {
        if (lines[i] ~ /^[[:space:]]*```/) break
        if (lines[i] !~ /^[[:space:]]*$/) break
      }
      end = first - 1
      while (end > 0 && lines[end] ~ /^[[:space:]]*$/) end--   # drop trailing blank lines
      for (i = 1; i <= end; i++) print lines[i]
    }
  '
}
