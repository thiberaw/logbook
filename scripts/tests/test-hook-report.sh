#!/usr/bin/env bash
# =============================================================================
# test-hook-report.sh — hermetic test for scripts/hook-report.sh  [TEST]
#
# WHAT IT TESTS:  the hook-health reporter against fixture logs, a fake hooks
#                 dir, and a throwaway sqlite db — pinning the 2a caveat
#                 (group by hook=, never tool=), the read-size-guard sub-class
#                 split, inert detection, the disarm tally, the sessions.db
#                 join (flagged/unmatched), and graceful degradation.
# HOW TO RUN:     `bash scripts/tests/test-hook-report.sh`
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
assert_contains() {   # <name> <fixed-string needle> <haystack>
  local name="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS: $name"
  else
    echo "  FAIL: $name"
    echo "    missing: $needle"
    FAILS=$((FAILS + 1))
  fi
}
assert_matches() {    # <name> <extended-regex> <haystack>
  local name="$1" re="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qE -- "$re"; then
    echo "  PASS: $name"
  else
    echo "  FAIL: $name"
    echo "    no line matching: $re"
    FAILS=$((FAILS + 1))
  fi
}
assert_absent() {     # <name> <fixed-string that must NOT appear> <haystack>
  local name="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  FAIL: $name"
    echo "    unexpectedly present: $needle"
    FAILS=$((FAILS + 1))
  else
    echo "  PASS: $name"
  fi
}

# --- fixtures ----------------------------------------------------------------
# Fake hooks dir: 4 instrumented (contain hook_log_fire), 1 not instrumented.
# Only 3 of the instrumented ones fire in the fixture log, so
# bulk-mcp-write-block must land in INERT and unrelated-hook must not appear.
mkdir -p "$TMP/hooks"
for h in read-size-guard bash-burst-warning scope-expansion-block bulk-mcp-write-block; do
  printf '#!/usr/bin/env bash\n# fixture\nhook_log_fire block Tool "x"\n' > "$TMP/hooks/$h.sh"
done
printf '#!/usr/bin/env bash\necho not instrumented\n' > "$TMP/hooks/unrelated-hook.sh"

# Fires log: note the bash-burst-warning line carries tool=Read — it must be
# grouped under bash-burst-warning (the 2a caveat). Last line is malformed.
cat > "$TMP/fires.log" <<'EOF'
2026-07-01T10:00:00+0200 hook=read-size-guard session=aaaaaaaa-1111 decision=block tool=Read detail="re-read /tmp/x.md"
2026-07-02T11:00:00+0200 hook=read-size-guard session=bbbbbbbb-2222 decision=block tool=Read detail="oversize 126996 chars: /tmp/big"
2026-07-03T12:00:00+0200 hook=bash-burst-warning session=aaaaaaaa-1111 decision=warn tool=Read detail="8 calls in 10s"
2026-07-04T13:00:00+0200 hook=scope-expansion-block session=cccccccc-3333 decision=block tool=Edit detail="scope shape"
this line is garbage
EOF

cat > "$TMP/reset.log" <<'EOF'
2026-07-04T13:05:00 session=cccccccc-3333 count=21 warned=clear
2026-07-05T09:00:00 session=dddddddd-4444 count=24 warned=DISARMED-BLOCK
EOF

# Throwaway sessions DB: aaaa… flagged, bbbb… clean, cccc… deliberately absent
# (must count as unmatched, never be silently dropped).
sqlite3 "$TMP/sessions.db" <<'EOF'
CREATE TABLE sessions (session_id TEXT, project TEXT, skill TEXT, flagged INTEGER);
INSERT INTO sessions VALUES ('aaaaaaaa-1111', 'acme-notes', 'improve', 1);
INSERT INTO sessions VALUES ('bbbbbbbb-2222', 'acme-app', 'review-pr', 0);
EOF

run_report() {   # runs the reporter against the fixtures; extra env via args
  env HOOK_FIRES_LOG="$TMP/fires.log" SCOPE_RESET_LOG="$TMP/reset.log" \
      HOOKS_DIR="$TMP/hooks" HOOK_REPORT_DB="$TMP/nonexistent.db" "$@" \
      bash "$SCRIPT_DIR/hook-report.sh"
}

echo "Testing hook-report.sh (core, log-only)..."
OUT="$(run_report)"

# 1. The 2a caveat pinned: the tool=Read burst line groups under its hook=.
assert_matches "groups by hook=, never tool=" '^bash-burst-warning  1 fires' "$OUT"
assert_matches "read-size-guard fire count" '^read-size-guard  2 fires' "$OUT"
# 2. read-size-guard sub-class split.
assert_contains "sub-class split" "sub-classes: re-read 1 · oversize 1" "$OUT"
# 3. Inert detection: instrumented-but-never-fired listed; non-instrumented not.
assert_contains "inert hook listed" "bulk-mcp-write-block" "$OUT"
assert_absent "non-instrumented hook excluded" "unrelated-hook" "$OUT"
# 4. Disarm tally from the reset log, on the scope-expansion-block block.
# Only DISARMED-BLOCK counts — warned=clear fires on every user prompt (a
# prompt counter, not a disarm event) and must not be printed.
assert_contains "disarm tally" "disarm log: 1 DISARMED-BLOCK all-time (first 2026-07-05 · last 2026-07-05)" "$OUT"
assert_absent "prompt-counter clears dropped" " clear " "$OUT"
# Malformed line counted, not fatal.
assert_contains "malformed line counted" "(1 malformed lines skipped)" "$OUT"
# Header shape (counts + coverage + skew present; 3 of 4 instrumented fired).
assert_matches "header coverage" '^4 fires · 3 of 4 instrumented hooks · skew: 50% read-size-guard' "$OUT"

# 5. sessions.db enrichment: flagged join, unmatched count, clusters.
echo "Testing hook-report.sh (sessions.db enrichment)..."
OUT_DB="$(env HOOK_FIRES_LOG="$TMP/fires.log" SCOPE_RESET_LOG="$TMP/reset.log" \
  HOOKS_DIR="$TMP/hooks" HOOK_REPORT_DB="$TMP/sessions.db" \
  bash "$SCRIPT_DIR/hook-report.sh")"

# read-size-guard fired in sessions aaaa (flagged) and bbbb (clean), both in DB.
assert_matches "flagged join" '^read-size-guard  2 fires \(. last 7d\) · 2 sessions · 1 flagged · 0 unmatched' "$OUT_DB"
# scope-expansion-block fired in cccc, which is NOT in the DB.
assert_matches "unmatched session" '^scope-expansion-block  1 fires \(. last 7d\) · 1 sessions · 0 flagged · 1 unmatched' "$OUT_DB"
# clusters resolve project/skill per fire.
assert_contains "cluster resolution" "acme-notes/improve 1" "$OUT_DB"
assert_absent "db-unavailable note absent when db present" "sessions.db unavailable" "$OUT_DB"

# DB missing → log-only degradation: header note present, enrichment absent.
assert_contains "db-missing header note" "(sessions.db unavailable — log-only output)" "$OUT"
assert_absent "no flagged column without db" "flagged" "$OUT"

# A corrupted session id must not break the DB query (it is filtered out
# before reaching the SQL string and counts as unmatched) — and must NOT
# misreport the DB as unavailable.
cat > "$TMP/fires-evil.log" <<'EOF'
2026-07-01T10:00:00+0200 hook=read-size-guard session=aaaaaaaa-1111 decision=block tool=Read detail="re-read /tmp/x.md"
2026-07-02T11:00:00+0200 hook=read-size-guard session=evil'quote decision=block tool=Read detail="re-read /tmp/y.md"
EOF
OUT_EVIL="$(env HOOK_FIRES_LOG="$TMP/fires-evil.log" SCOPE_RESET_LOG="$TMP/reset.log" \
  HOOKS_DIR="$TMP/hooks" HOOK_REPORT_DB="$TMP/sessions.db" \
  bash "$SCRIPT_DIR/hook-report.sh")"
assert_absent "corrupt id does not kill enrichment" "sessions.db unavailable" "$OUT_EVIL"
assert_matches "corrupt id counts as unmatched" '^read-size-guard  2 fires \(. last 7d\) · 2 sessions · 1 flagged · 1 unmatched' "$OUT_EVIL"

# 6. Empty fires log → "no telemetry yet", exit 0.
: > "$TMP/empty.log"
RC=0
OUT_EMPTY="$(env HOOK_FIRES_LOG="$TMP/empty.log" SCOPE_RESET_LOG="$TMP/reset.log" \
  HOOKS_DIR="$TMP/hooks" HOOK_REPORT_DB="$TMP/nonexistent.db" \
  bash "$SCRIPT_DIR/hook-report.sh")" || RC=$?
assert_contains "empty log degrades" "no telemetry yet" "$OUT_EMPTY"
if [ "$RC" -eq 0 ]; then echo "  PASS: empty log exits 0"; else
  echo "  FAIL: empty log exited $RC"; FAILS=$((FAILS + 1)); fi

if [ "$FAILS" -eq 0 ]; then
  echo "PASS: hook-report core behaviour pinned"
else
  echo "FAIL: $FAILS assertion(s) failed"
  exit 1
fi
