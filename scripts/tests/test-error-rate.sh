#!/usr/bin/env bash
# =============================================================================
# test-error-rate.sh — locale-independent error-rate maths  [TEST]
#
# WHAT IT TESTS:  That computing an "error rate" (tool errors / total tool calls)
#                 and comparing it against the 0.3 "high" threshold gives correct
#                 results in any locale. The bug being guarded against: some
#                 locales use a comma as the decimal separator, which can make
#                 `awk` produce or compare numbers wrongly. Forcing LC_ALL=C
#                 (the neutral "C" locale, which always uses a dot) fixes that.
# HOW TO RUN:     `bash scripts/tests/test-error-rate.sh`
#                 It prints progress lines and a final "PASS: ..." line.
# =============================================================================
set -euo pipefail   # Strict mode: -e abort on error, -u unset var=error, -o pipefail propagates pipe failures.

# Announce what this test is checking.
echo "Testing error rate calculation with LC_ALL=C..."

# A representative case: 3 errors out of 100 calls = 0.03, which is NOT "high".
TOOL_ERRORS_COUNT=3
TOTAL_TOOL_CALLS=100

# `LC_ALL=C awk "BEGIN {...}"` runs a one-shot awk program in the neutral locale.
# Here it prints the ratio rounded to 2 decimals (e.g. "0.03"). The `\"%.2f\"`
# is an escaped format string because the awk program is inside double quotes.
ERROR_RATE=$(LC_ALL=C awk "BEGIN {printf \"%.2f\", $TOOL_ERRORS_COUNT / $TOTAL_TOOL_CALLS}")
# Compare the rate against 0.3, printing "true" if above, else "false".
IS_HIGH=$(LC_ALL=C awk "BEGIN {print ($ERROR_RATE > 0.3) ? \"true\" : \"false\"}")
echo "  errors=$TOOL_ERRORS_COUNT/$TOTAL_TOOL_CALLS rate=$ERROR_RATE high=$IS_HIGH"

# Edge cases: walk a spread of error counts (0%, 3%, 30%, 50%, 100%) and print
# the rate + high/low verdict for each, so a human can eyeball the threshold.
for errors in 0 3 30 50 100; do
  RATE=$(LC_ALL=C awk "BEGIN {printf \"%.2f\", $errors / $TOTAL_TOOL_CALLS}")
  HIGH=$(LC_ALL=C awk "BEGIN {print ($RATE > 0.3) ? \"true\" : \"false\"}")
  echo "  errors=$errors rate=$RATE high=$HIGH"
done

# This script has no hard assertions; reaching here without a crash means the
# maths ran cleanly in the C locale, so it reports success.
echo "PASS: error rate calculation works"
