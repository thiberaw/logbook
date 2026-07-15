#!/usr/bin/env bash
# =============================================================================
# narrative-check.sh — narrative confabulation detector  [LIBRARY — sourced]
#
# WHAT IT IS:  a cheap deterministic cross-check that compares the LLM-generated
#              narrative against the metrics we KNOW are true. The narrative is
#              written by haiku from a lossy head+tail trace with no tool
#              results (see transcript-analyzer.py), so it confabulates:
#              confident, specific, and sometimes wrong. This catches the
#              checkable contradictions so a low-confidence narrative can be
#              marked instead of trusted.
# SOURCED BY:  session-end-worker.sh (to set a confidence marker), and the
#              prototype demo runner.
# PROVIDES:    validate_narrative — print "high"/"low" + the contradictions
#
# It deliberately only checks what is DETERMINISTICALLY KNOWN — file/commit
# counts, test result, turn/tool counts, and whether cited commit hashes are
# real. It does NOT second-guess the prose; a clean check is necessary, not
# sufficient, for trust.
# =============================================================================

# validate_narrative — cross-check one narrative against its session facts.
# args:
#   1  narrative text (the 5-section markdown)
#   2  files_modified  (int)
#   3  commit_count    (int; -1 = unknown)
#   4  tests_passed    (true|false|null)
#   5  turns           (int)
#   6  tool_calls      (int)
#   7  outcome         (success|partial|abandoned|wrong_approach|"")
#   8  known_hashes    (space-separated real commit hashes for this session, optional)
#   9  repo_dir        (the session's repo dir, for resolving cited hashes; optional)
# Prints one line: "<high|low>\t<semicolon-joined reasons, or '-'>"
validate_narrative() {
  local n="$1" files="${2:-0}" commits="${3:--1}" tests="${4:-null}"
  local turns="${5:-0}" calls="${6:-0}" outcome="${7:-}" known_hashes="${8:-}" repo_dir="${9:-.}"
  local reasons=() nl
  nl=$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]')

  # 1. Claims nothing shipped, but artifacts exist. "nothing shipped" is the
  #    narrative prompt's own suggested phrase for the Outcome section, so we
  #    scan ONLY that section: Goal/Approach routinely QUOTE other sessions'
  #    states when the narrative describes adjudication work (an /improve
  #    narrative once quoted "files modified but no commits" about the
  #    sessions it was reviewing and drew a bogus low despite citing its own
  #    real commit). Narratives without an Outcome header fall back
  #    to whole-text scanning.
  # NB: a local named `outcome` here would shadow the outcome-verdict arg that
  # check #4 reads — that shadow once silently killed check #4.
  local outcome_section
  outcome_section=$(printf '%s' "$nl" | sed -n '/^## outcome/,/^## /p')
  [ -z "$outcome_section" ] && outcome_section="$nl"
  if printf '%s' "$outcome_section" | grep -qE 'nothing shipped|no code (was )?(committed|changed)|(0|zero|no) commits|no files (were )?(modified|changed)'; then
    if [ "${files:-0}" -gt 0 ] || { [ "$commits" != "-1" ] && [ "${commits:-0}" -gt 0 ]; }; then
      reasons+=("claims nothing shipped but files_modified=${files}, commits=${commits}")
    fi
  fi

  # 2. Claims tests pass, but the metrics detected a failure.
  if [ "$tests" = "false" ] && printf '%s' "$nl" | grep -qE 'tests? (all |suite )?(pass|green)|all (tests )?(pass|green)|suite (is )?green'; then
    reasons+=("claims tests pass but tests_passed=false")
  fi

  # 3. Cites a commit hash that does not exist in the repo at all (a true
  #    confabulation). A hash from a PRIOR session is still real and legitimate
  #    context — narratives in a self-referential repo routinely reference recent
  #    commits — so we only flag hashes that resolve nowhere. (A session once
  #    cited two real prior repo commits, and was
  #    wrongly marked unverified because they weren't from this session.)
  #    Only runs when we were handed the session's hash list (else we can't judge).
  #    Also probe ~/.claude and the tool repo — /improve (and any data-repo
  #    session) routinely applies findings to the claude-settings repo AND to
  #    this tool repo, so cited hashes can legitimately live in either rather
  #    than in the session's CWD repo (real commits in both were once wrongly
  #    flagged as confabulation). The tool repo is self-located from this
  #    script's own path, never hardcoded.
  if [ -n "$known_hashes" ]; then
    local tool_root
    tool_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local h probe_dirs=("$repo_dir" "$HOME/.claude" "$tool_root")
    # Pure-decimal tokens (customer/user IDs, counts, byte sizes) are valid hex
    # but are not commits — grep -v them out, or a 7-digit ID like a user ID
    # gets probed as a hash and flagged "not found" (a narrative once cited a
    # 7-digit user ID and drew a bogus "cites commit <id> not found" low).
    for h in $(printf '%s' "$n" | grep -oE '\b[0-9a-f]{7,40}\b' | grep -vE '^[0-9]+$' | sort -u); do
      # match on shared 7-char prefix in either direction (abbrev hashes vary)
      local short="${h:0:7}" found=0 kh d
      for kh in $known_hashes; do
        [ "${kh:0:7}" = "$short" ] && { found=1; break; }
      done
      # Not in this session — but if it resolves to a real commit in any repo a
      # session may commit to (its CWD repo, ~/.claude, or the tool repo), it's
      # legitimate prior-work context, not a confabulation.
      for d in "${probe_dirs[@]}"; do
        [ "$found" -eq 0 ] || break
        git -C "$d" cat-file -e "${short}^{commit}" 2>/dev/null && found=1
      done
      [ "$found" -eq 0 ] && reasons+=("cites commit ${short} not found in repo")
    done
  fi

  # 4. Outcome verdict contradicts a no-op session: a 0-turn / 0-tool-call
  #    session can't have been "abandoned" or "wrong_approach" — nothing was
  #    attempted (a 0-turn /exit row once mislabelled "abandoned").
  if [ "${turns:-0}" -eq 0 ] && [ "${calls:-0}" -eq 0 ] \
     && { [ "$outcome" = "abandoned" ] || [ "$outcome" = "wrong_approach" ]; }; then
    reasons+=("outcome='${outcome}' on a 0-turn/0-call session (nothing attempted)")
  fi

  if [ ${#reasons[@]} -eq 0 ]; then
    printf 'high\t-\n'
  else
    local IFS='; '
    printf 'low\t%s\n' "${reasons[*]}"
  fi
}
