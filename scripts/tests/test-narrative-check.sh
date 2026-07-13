#!/usr/bin/env bash
# =============================================================================
# test-narrative-check.sh — narrative confabulation cross-check  [TEST]
#
# WHAT IT TESTS:  validate_narrative from lib/narrative-check.sh, focusing on
#                 check #3 (cited-commit resolution). The key regression guarded
#                 here is the cross-repo fix: a hash that is real in
#                 ~/.claude (where /improve applies its findings) must NOT be
#                 flagged as confabulation just because it's absent from the
#                 session's CWD repo. A genuinely fabricated hash must still flag.
# HOW TO RUN:     `bash scripts/tests/test-narrative-check.sh`
#                 Builds two throwaway git repos under a temp HOME so the probe
#                 is hermetic (no dependency on the caller's real ~/.claude), then
#                 prints PASS/FAIL per assertion and a final verdict.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/narrative-check.sh"

FAILS=0

# assert_verdict <name> <expected-verdict> <full-output-line>: the function prints
# "<high|low>\t<reasons>"; we compare only the leading verdict field.
assert_verdict() {
  local name="$1" expected="$2" line="$3" got="${3%%$'\t'*}"
  if [ "$expected" = "$got" ]; then
    echo "  PASS: $name"
  else
    echo "  FAIL: $name"
    echo "    expected verdict: $expected"
    echo "    actual line:      $(printf '%q' "$line")"
    FAILS=$((FAILS + 1))
  fi
}

echo "Testing validate_narrative commit-resolution (check #3)..."

# Build a hermetic environment: a temp HOME holding a fake ~/.claude git repo
# (the claude-settings repo /improve commits to) plus a separate "session" repo
# that stands in for the session's CWD repo. Both get one real commit each.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"           # validate_narrative probes "$HOME/.claude"
mkdir -p "$HOME"

git_init_with_commit() {          # <dir> -> echoes the new commit's short hash
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "seed"
  git -C "$d" rev-parse --short HEAD
}

CLAUDE_HASH="$(git_init_with_commit "$HOME/.claude")"   # real, but in ~/.claude only
SESSION_DIR="$TMP/session"
SESSION_HASH="$(git_init_with_commit "$SESSION_DIR")"   # real, in the session CWD repo

# Case 1 (the cross-repo regression): a hash real only in ~/.claude, not handed
# in as a known session hash, must resolve to high — not be called confabulation.
assert_verdict "cross-repo ~/.claude hash -> high" "high" \
  "$(validate_narrative "Applied findings in commit ${CLAUDE_HASH} to the settings repo." \
       2 1 null 14 21 success "deadbee" "$SESSION_DIR")"

# Case 2: a hash real in the session's own CWD repo still resolves to high.
assert_verdict "session CWD repo hash -> high" "high" \
  "$(validate_narrative "Fixed in commit ${SESSION_HASH}." \
       1 1 null 5 9 success "deadbee" "$SESSION_DIR")"

# Case 3: a hash listed as a known session hash resolves to high (fast path,
# before any repo probe).
assert_verdict "known session hash -> high" "high" \
  "$(validate_narrative "Shipped as abc1234." \
       1 1 null 5 9 success "abc1234" "$SESSION_DIR")"

# Case 4: a genuinely fabricated hash (real in no repo, not a known hash) must
# still flag low — the fix must not blanket-pass everything.
assert_verdict "fabricated hash -> low" "low" \
  "$(validate_narrative "Applied in commit deadbee9." \
       2 1 null 14 21 success "abc1234" "$SESSION_DIR")"

# Case 5: an unrelated check (#1 nothing-shipped vs artifacts) still fires,
# independent of the commit probe, so the fix didn't disturb the other checks.
assert_verdict "nothing-shipped contradiction -> low" "low" \
  "$(validate_narrative "Nothing shipped this session." \
       3 0 null 8 12 partial "" "$SESSION_DIR")"

# Case 6: a pure-numeric customer/user ID is valid hex but is a
# decimal ID, not a commit — it must not be probed as a hash and flagged.
# A narrative once cited a 7-digit user ID and drew a bogus
# "cites commit <id> not found in repo" low.
assert_verdict "pure-numeric ID not treated as hash -> high" "high" \
  "$(validate_narrative "Set the display name for user ID 1274923." \
       3 1 null 10 20 success "abc1234" "$SESSION_DIR")"

# Case 7: check #1 must scan only the Outcome section. A narrative
# whose Approach QUOTES another session's state ("files modified but no commits")
# while its own Outcome cites a real commit must stay high — an
# /improve narrative once drew a bogus "claims nothing shipped" low this way.
QUOTED_NARR="## Goal
Process flagged sessions.
## Approach
Verified both were check-#1 false positives (files modified but no commits).
## Outcome
Successfully modified docs/open-concerns.md in commit ${SESSION_HASH}.
## Friction
None."
assert_verdict "quoted 'no commits' outside Outcome -> high" "high" \
  "$(validate_narrative "$QUOTED_NARR" \
       1 1 null 18 19 success "$SESSION_HASH" "$SESSION_DIR")"

# Case 8: a genuine nothing-shipped claim INSIDE the Outcome section still
# contradicts commits>0 and must flag low — the scoping must not blind check #1.
OUTCOME_NARR="## Goal
Fix the bug.
## Outcome
Nothing shipped this session.
## Friction
None."
assert_verdict "nothing-shipped inside Outcome -> low" "low" \
  "$(validate_narrative "$OUTCOME_NARR" \
       2 1 null 8 12 partial "" "$SESSION_DIR")"

if [ "$FAILS" -eq 0 ]; then
  echo "PASS: validate_narrative resolves cross-repo (~/.claude) commits without false confabulation flags"
else
  echo "FAIL: $FAILS assertion(s) failed"
  exit 1
fi
