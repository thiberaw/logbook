#!/usr/bin/env bash
# =============================================================================
# git-activity.sh — GitHub PR/commit scanning helpers  [LIBRARY — sourced, not run]
#
# WHAT IT IS : a function library. It has no top-to-bottom "main" logic; it just
#              defines functions that other scripts call.
# SOURCED BY : morning-review.sh (and its enrich_daily subshell) to collect the
#              PRs a user opened or merged on a given day.
# PROVIDES   :
#   _fetch_prs        — (private) ask GitHub for one repo's PRs matching a query.
#   scan_pull_requests — (public) gather all of a day's PRs across every repo.
# =============================================================================

# Absolute path to THIS file's directory, resolved even if sourced via a symlink.
# `${BASH_SOURCE[0]}` is this file's path; `dirname` strips the filename; the
# `cd ... && pwd` turns it into a clean absolute path.
_GIT_ACTIVITY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Pull in shared config (defines GIT_USER, repo detection helpers, etc.).
source "$_GIT_ACTIVITY_DIR/../config.sh"
# PII scrub — PR titles routinely name customers ("TICKET-123 Delete blocking
# draft for <org>") and the scanned PR data is written into committed daily
# JSON, so scrub it at fetch time.
source "$_GIT_ACTIVITY_DIR/pii-scrub.sh"

# --- _fetch_prs (private) ----------------------------------------------------
# Fetch PRs from a single repo matching a search query.
# Usage: _fetch_prs "owner/repo" "created:2026-02-18..2026-02-19" "all"
_fetch_prs() {
  # `local` keeps these names scoped to this function; $1/$2/$3 are the args.
  local repo="$1" search="$2" state="$3"
  # `gh` is GitHub's CLI. This lists PRs authored by GIT_USER in one repo,
  # filtered by state and the search query, returning the chosen JSON fields.
  gh pr list --repo "$repo" \
    --author "$GIT_USER" \
    --state "$state" \
    --search "$search" \
    --json number,title,state,url,createdAt,mergedAt \
    --limit 20 2>/dev/null || echo "[]"
    # `2>/dev/null` discards error text; `|| echo "[]"` yields an empty JSON
    # array on failure so callers always get valid JSON to parse.
}

# --- scan_pull_requests (public) ---------------------------------------------
# Scan GitHub repos for PRs created or merged on a given date.
# Usage: scan_pull_requests "2026-02-18"
# Output: JSON array [ { repo, number, title, state, url, created_at, merged_at } ]
scan_pull_requests() {
  local date="$1"
  local next_date
  # GitHub date ranges are half-open, so we need "the day after" as the upper
  # bound. `portable_date` (from config.sh) does date math that works on both
  # GNU and BSD/macOS `date`; here: take $date and add one day.
  next_date=$(portable_date "+1 day" "%Y-%m-%d" "$date")

  local repos
  # List of repos to scan, one "owner/repo" per line (defined in config.sh).
  repos=$(detect_github_repos)

  # Accumulator: starts as an empty JSON array, grows one repo at a time.
  local all_prs="[]"

  # Unquoted `$repos` here is intentional: word-splitting turns the multi-line
  # string into one loop iteration per repo.
  for repo in $repos; do
    # Skip anything that isn't an "owner/repo" slug (the `*"/"*` glob requires
    # a slash); `|| continue` jumps to the next repo.
    [[ "$repo" == *"/"* ]] || continue

    local created merged
    # Two separate queries: PRs opened on this day, and PRs merged on this day.
    created=$(_fetch_prs "$repo" "created:${date}..${next_date} sort:created-desc" "all")
    merged=$(_fetch_prs "$repo" "merged:${date}..${next_date}" "merged")

    local repo_short
    # `sed 's#.*/##'` deletes everything up to and including the last slash,
    # leaving just the repo name (e.g. "acme/my-app" → "my-app").
    repo_short=$(echo "$repo" | sed 's#.*/##')

    local combined
    # `jq -n` builds JSON from scratch (no input doc); `--argjson` injects the
    # two PR arrays as real JSON. The filter concatenates them, drops duplicate
    # PR numbers (a PR can be both created and merged today), and tags each
    # entry with its short repo name.
    combined=$(jq -n \
      --argjson created "$created" \
      --argjson merged "$merged" \
      --arg repo "$repo_short" '
      ($created + $merged)
      | unique_by(.number)
      | map(. + { repo: $repo })
    ' 2>/dev/null || echo "[]")

    # Append this repo's PRs to the running total (array concatenation in jq).
    all_prs=$(jq -n --argjson existing "$all_prs" --argjson new "$combined" '$existing + $new')
  done

  # Emit the merged JSON array on stdout, scrubbed. scrub_pii is JSON-safe
  # (replacements contain no quotes/backslashes), so running the whole array
  # through it cleans titles without disturbing the structure.
  echo "$all_prs" | scrub_pii
}
