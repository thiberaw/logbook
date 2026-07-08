#!/usr/bin/env bash
# =============================================================================
# test-pii-scrub.sh — unit tests for lib/pii-scrub.sh
#
# Deterministic, no network, no LLM — runs in the default test sweep.
# Uses a throwaway STATE_DIR with a synthetic denylist so the test never
# depends on (or leaks) the real gitignored denylist.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Throwaway state dir with a synthetic denylist.
STATE_DIR=$(mktemp -d)
trap 'rm -rf "$STATE_DIR"' EXIT
cat > "$STATE_DIR/pii-denylist.txt" << 'EOF'
# synthetic test denylist
Acme Corp|<customer-org>
Jane Doe|<customer-name>
Globex|<customer-org>
EOF

source "$SCRIPT_DIR/lib/pii-scrub.sh"

FAILED=0
check() {
  local name="$1" input="$2" expected="$3" actual
  actual=$(printf '%s' "$input" | scrub_pii)
  if [ "$actual" = "$expected" ]; then
    echo "PASS $name"
  else
    echo "FAIL $name"
    echo "  input:    $input"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    FAILED=1
  fi
}

check "email" \
  "contact jane.doe+x@sub.example.co.uk now" \
  "contact <email> now"

check "atlassian browse URL collapses to ticket key" \
  "see https://example-co.atlassian.net/browse/SUP-501 for context" \
  "see SUP-501 for context"

check "other atlassian URL becomes Jira" \
  "posted to https://example-co.atlassian.net/secure/Dashboard.jspa today" \
  "posted to Jira today"

check "bare atlassian hostname becomes Jira" \
  "the example-co.atlassian.net instance" \
  "the Jira instance"

check "org id" \
  "customer org 1234567 hit the cap" \
  "customer org <id> hit the cap"

check "denylist multiword term, case-insensitive" \
  "ticket from ACME CORP about workflows" \
  "ticket from <customer-org> about workflows"

check "denylist person name" \
  "reporter Jane Doe cannot log in" \
  "reporter <customer-name> cannot log in"

check "single-word term respects word boundaries" \
  "legacy Globex account moved to Globexton office" \
  "legacy <customer-org> account moved to Globexton office"

check "ticket keys and repo names untouched" \
  "SUP-123 fixed in acme-app" \
  "SUP-123 fixed in acme-app"

# JSON safety: scrubbing a JSON document must keep it parseable.
JSON_IN='[{"title":"SUP-452 Delete blocking draft for Acme Corp","url":"https://github.com/x/y/pull/1"}]'
JSON_OUT=$(printf '%s' "$JSON_IN" | scrub_pii)
if printf '%s' "$JSON_OUT" | jq -e '.[0].title == "SUP-452 Delete blocking draft for <customer-org>"' >/dev/null; then
  echo "PASS json stays valid and title scrubbed"
else
  echo "FAIL json scrub — got: $JSON_OUT"
  FAILED=1
fi

# No denylist present: mechanical layer still works, no error.
STATE_DIR_SAVE="$STATE_DIR"
STATE_DIR=$(mktemp -d)
OUT=$(printf '%s' "mail a@b.io" | scrub_pii)
rm -rf "$STATE_DIR"
STATE_DIR="$STATE_DIR_SAVE"
if [ "$OUT" = "mail <email>" ]; then
  echo "PASS works without a denylist"
else
  echo "FAIL no-denylist path — got: $OUT"
  FAILED=1
fi

exit $FAILED
