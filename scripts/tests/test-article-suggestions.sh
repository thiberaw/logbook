#!/usr/bin/env bash
# =============================================================================
# test-article-suggestions.sh — stale re-surfacing fallback  [TEST]
#
# WHAT IT TESTS:  _select_articles + _write_articles_to_daily from
#                 lib/article-suggestions.sh, focusing on the 2026-07-03
#                 stale-fallback: when every non-release article in the cache
#                 has already been seen, the day should still surface the top
#                 articles tagged {stale:true} instead of a blank section —
#                 while releases stay unseen-only (fallback scoped to articles).
# HOW TO RUN:     `bash scripts/tests/test-article-suggestions.sh`
#                 Runs hermetically against a temp STATE_DIR/DAILY_DIR with a
#                 fixture cache + seen file; touches no real state or network.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/config.sh"          # sets STATE_DIR/DAILY_DIR (to real dirs)

# Repoint state + daily at a throwaway sandbox, THEN source the libs so
# logging's LOG_FILE and the article functions all read the temp paths.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE_DIR="$TMP/state"
DAILY_DIR="$TMP/daily"
mkdir -p "$STATE_DIR" "$DAILY_DIR"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/logging.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/article-suggestions.sh"

TODAY="$(date +%Y-%m-%d)"
CACHE="$STATE_DIR/articles-cache.json"
SEEN="$STATE_DIR/articles-seen.json"
DAILY="$DAILY_DIR/$TODAY.json"

FAILS=0
assert_eq() {  # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  PASS: $1"
  else
    echo "  FAIL: $1 (expected '$2', got '$3')"
    FAILS=$((FAILS + 1))
  fi
}

# Fixture cache: one release (priority 0) + three non-release articles.
cat > "$CACHE" <<'JSON'
{
  "fetched_at": "2026-07-03T08:00:00Z",
  "articles": [
    {"title": "Claude Code v9.9.9", "url": "https://example.com/rel", "source_domain": "github.com", "description": "", "priority": 0, "is_release": true},
    {"title": "Fresh article A", "url": "https://example.com/a", "source_domain": "a.com", "description": "desc a", "priority": 1},
    {"title": "Fresh article B", "url": "https://example.com/b", "source_domain": "b.com", "description": "desc b", "priority": 3},
    {"title": "Fresh article C", "url": "https://example.com/c", "source_domain": "c.com", "description": "desc c", "priority": 4}
  ]
}
JSON

# --- Case A: everything already seen (releases + all articles) ---------------
# Releases must stay empty (unseen-only); articles must fall back to stale.
echo "Case A — all seen: articles re-surface stale, releases stay empty"
jq '[.articles[] | (.url | @base64)]' "$CACHE" > "$SEEN"
echo '{}' > "$DAILY"
show_article_suggestions_silent

assert_eq "3 stale articles surfaced"        "3" "$(jq '.suggested_articles | length' "$DAILY")"
assert_eq "every surfaced article is stale"  "3" "$(jq '[.suggested_articles[] | select(.stale == true)] | length' "$DAILY")"
assert_eq "releases empty (no stale fallback)" "0" "$(jq '.claude_releases | length' "$DAILY")"

# --- Case B: one article unseen ----------------------------------------------
# Fresh path wins: only the unseen article surfaces, and nothing is tagged stale.
echo "Case B — one unseen: fresh path, no stale tag"
jq '[.articles[] | select(.url != "https://example.com/b") | (.url | @base64)]' "$CACHE" > "$SEEN"
echo '{}' > "$DAILY"
show_article_suggestions_silent

assert_eq "only the 1 unseen article surfaces" "1" "$(jq '.suggested_articles | length' "$DAILY")"
assert_eq "it is the unseen article B"         "Fresh article B" "$(jq -r '.suggested_articles[0].title' "$DAILY")"
assert_eq "no article tagged stale"            "0" "$(jq '[.suggested_articles[] | select(.stale == true)] | length' "$DAILY")"

echo ""
if [ "$FAILS" -eq 0 ]; then
  echo "ALL PASS (test-article-suggestions.sh)"
  exit 0
else
  echo "FAILED: $FAILS assertion(s) (test-article-suggestions.sh)"
  exit 1
fi
