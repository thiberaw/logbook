#!/usr/bin/env bash
# =============================================================================
# pii-scrub.sh — customer-PII scrubber  [LIBRARY — sourced, not run]
#
# WHAT IT IS:  the single scrub applied to everything the pipeline RECORDS
#              (DB narratives, flag analyses, first prompts, session names,
#              PR titles) and RENDERS (reviewed/*.md reports). Added
#              after a repo-wide scrub found customer names and customer
#              orgs in committed reviewed files — scrubbing at write time keeps
#              the DB and the committed markdown clean at the source.
# SOURCED BY:  session-end-worker.sh, lib/daily-report.sh, lib/git-activity.sh,
#              scripts/tests/test-pii-scrub.sh. Source config.sh first
#              (the denylist lives under $STATE_DIR).
# PROVIDES:    scrub_pii — stdin -> stdout filter
#
# TWO LAYERS:
#   1. Mechanical patterns (always on): email addresses, atlassian.net URLs
#      (browse links collapse to the bare ticket key), customer org/user IDs.
#   2. Denylist ($STATE_DIR/pii-denylist.txt, OPTIONAL): customer names and
#      org names that no regex can recognize. One entry per line:
#          term|replacement        e.g.  Acme Corp|<customer-org>
#      Lines starting with # are comments; replacement defaults to
#      <customer-org> when omitted. Single-word terms are matched on word
#      boundaries (so "Globex" never hits "Globexton"); matching is
#      case-insensitive. The file is gitignored ON PURPOSE — a list of
#      customer names is itself PII and must never be committed. Seed it
#      with each customer that appears in a support session; the LLM prompt
#      rules are the first line of defense, this list catches the slips.
# =============================================================================

# scrub_pii — filter stdin to stdout. Safe on JSON (replacements contain no
# quotes or backslashes) and on markdown.
scrub_pii() {
  local denylist="${STATE_DIR:-/nonexistent}/pii-denylist.txt"

  # Layer 1 — mechanical patterns. Same atlassian collapse as the historical
  # report sanitizer, plus emails and numeric org/user IDs.
  sed -E \
    -e 's#https?://[a-zA-Z0-9][a-zA-Z0-9.-]*\.atlassian\.net/browse/([A-Z]+-[0-9]+)#\1#g' \
    -e 's#https?://[a-zA-Z0-9][a-zA-Z0-9.-]*\.atlassian\.net[^[:space:])"`'"'"']*#Jira#g' \
    -e 's#`[a-zA-Z0-9][a-zA-Z0-9.-]*\.atlassian\.net`#`Jira`#g' \
    -e 's#[a-zA-Z0-9][a-zA-Z0-9.-]*\.atlassian\.net#Jira#g' \
    -e 's#[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}#<email>#g' \
    -e 's#\borg(anization)? [0-9]{5,}#org <id>#g' \
  | {
    # Layer 2 — denylist, if present.
    if [ -f "$denylist" ]; then
      local args=() term repl escaped
      while IFS='|' read -r term repl; do
        [ -z "$term" ] && continue
        case "$term" in \#*) continue ;; esac
        # Escape sed-special characters in the term (it is plain text).
        escaped=$(printf '%s' "$term" | sed 's/[.[\*^$\/&]/\\&/g')
        # Word-boundary guard for single-word terms only — multiword terms
        # and terms with punctuation are unambiguous enough as-is.
        if printf '%s' "$term" | grep -qE '^[A-Za-z0-9]+$'; then
          escaped="\b${escaped}\b"
        fi
        args+=(-e "s/${escaped}/${repl:-<customer-org>}/Ig")
      done < "$denylist"
      if [ ${#args[@]} -gt 0 ]; then
        sed -E "${args[@]}"
      else
        cat
      fi
    else
      cat
    fi
  }
}
