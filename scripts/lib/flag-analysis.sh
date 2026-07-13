#!/usr/bin/env bash
# =============================================================================
# flag-analysis.sh — flag-analysis prompt builder  [LIBRARY — sourced, not run]
#
# WHAT IT IS:  the single source of truth for the sonnet flag-analysis prompt.
#              Extracted from session-end-worker.sh so the worker
#              and the regression test (scripts/tests/test-flag-analysis.sh)
#              exercise the EXACT same prompt — prompt edits that change flag
#              behavior must pass the golden-corpus test before shipping.
# SOURCED BY:  session-end-worker.sh, scripts/tests/test-flag-analysis.sh
# PROVIDES:    build_flag_prompt — assemble the prompt from session context
#              extract_flag_json — pull the JSON verdict out of raw LLM output
#
# CALIBRATION lessons baked into this prompt (dated history lives in the data
# dir's hooks-changelog.md):
#   - The null gate leads: the model explained instead of nulling until "null is
#     a valid verdict" became rule 1 — which then over-corrected into clearing
#     every flag, so the GENUINE criteria and the "roughly a third are genuine"
#     anchor exist to hold the middle.
#   - The read-only/no-output false positives an earlier null-biasing lead
#     guarded against are handled deterministically by the EFFECTIVE_SKILL
#     exemptions, not by this prompt.
#   - When prompt-level fixes repeatedly fail to move the confirmed-flag rate,
#     the model is the remaining lever (a model bump is what finally lifted the
#     rate off ~0% after three failed prompt tweaks); leave the prompt untouched
#     when bumping, to isolate the variable.
# =============================================================================

# The model the flag analysis runs on — shared so the regression test exercises
# the same model the worker uses. Changing this is a measurement change: run the
# golden test (RUN_LLM_TESTS=1) before shipping.
FLAG_ANALYSIS_MODEL="claude-sonnet-4-6"

# build_flag_prompt — print the full prompt on stdout.
# args: 1=condensed_transcript 2=flag_reasons 3=project 4=branch
#       5=duration_min 6=cost_usd 7=turns 8=tool_calls 9=tool_errors 10=files_modified
build_flag_prompt() {
  local condensed="$1" flag_reasons="$2" project="$3" branch="$4"
  local duration="$5" cost="$6" turns="$7" tool_calls="$8" errors="$9" files="${10}"
  local cpt
  # Cost per turn, guarded against zero turns; LC_ALL=C forces a "." decimal point.
  cpt=$(LC_ALL=C awk "BEGIN {printf \"%.2f\", $cost / ($turns > 0 ? $turns : 1)}")
  # Unquoted heredoc: ${vars} interpolate; literal dollar signs are escaped as \$.
  cat <<EOF
You are Claude analyzing a Claude Code session transcript. This is AI reflecting on its own usage patterns.

Flags that triggered this review: ${flag_reasons}

Session: ${project} on branch ${branch}, ${duration}min, \$${cost}
Turns: ${turns}, tool calls: ${tool_calls}, errors: ${errors}, files: ${files}
Cost per turn: \$${cpt}

Condensed transcript:
${condensed}

Respond with ONLY a JSON object (no markdown):
{
  "issue": "What went wrong and why — be specific about the root cause (e.g. 'Claude entered an exploration spiral: 12 Grep calls searching for the wrong abstraction layer because the initial search was too broad')",
  "suggestion": "A project-agnostic change the user or their setup could make to prevent this — a global CLAUDE.md rule, a skill change, or a workflow habit (e.g. 'always check the last commit first when investigating recent changes'). Keep the evidence specific but do NOT recommend a rule scoped to one project's CLAUDE.md."
}

Rules:
- Adjudicate this flag on its merits: read the transcript and decide whether it reflects real waste or failure. A flag is GENUINE when the transcript shows the goal was abandoned or not reached; the user rejected or had to redirect Claude's actions; repeated hook-block + clear-retry cycles; error or retry spirals; long polling or re-reading loops; or cost concentrated in turns that produced nothing the user kept. For a high-cost flag, 'the task was big' only clears it if the cost demonstrably went into the task itself, not into friction.
- Calibration: roughly a third of heuristic flags are genuine. Confirming every flag and nulling every flag are equally wrong — the heuristics (turn/file/cost thresholds) do misfire, notably on high-but-justified cost, so weigh the transcript, not the threshold.
- When the flag is genuine, describe it and be brutally specific: reference actual tool names, file paths, and turn counts from the transcript. Do NOT give generic advice like 'be more explicit' or 'add constraints'; point to the exact moment things went wrong. If cost-per-turn exceeds \$1.00 on a session that underperformed, investigate what made those turns expensive (large file reads, repeated searches, unnecessary tool calls).
- When the transcript shows the session went fine, respond with EXACTLY {"issue": null, "suggestion": null} — null is a valid verdict, not a fallback. Do not use the issue field to explain or critique the flagging system.
- Focus on patterns that recur across sessions, not one-off flukes.
- NEVER include customer names, personal names, email addresses, or customer organization names in the issue or suggestion — refer to them generically ('the customer', 'a user', 'the org'). Internal file paths, repo names, and ticket keys are fine. This text is recorded and rendered into committed reports.
EOF
}

# extract_flag_json — pull the {...} verdict block out of possibly-chatty LLM
# output. Reads the raw text as $1, prints the JSON block (or nothing).
# sed: start at the first line beginning with "{", keep appending lines (N;ba
# loop) until one ends with "}", print that block (p) and quit (q).
extract_flag_json() {
  printf '%s' "$1" | sed -n '/^{/{:a;/}$/!{N;ba};p;q}'
}
