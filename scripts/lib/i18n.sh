#!/usr/bin/env bash
# =============================================================================
# i18n.sh — UI string table  [LIBRARY — sourced, not run]
#
# WHAT IT IS: a string table, not executable logic. Sourcing this file defines
#   a batch of I18N_* shell variables holding the user-facing text for the
#   morning-review / weekly TUI scripts. Other scripts then read those I18N_*
#   variables (e.g. printf "$I18N_SESSIONS" "$n") to print the text.
#   Note: some strings contain printf placeholders (%s, %d, %%) and \$ literals,
#   which the calling scripts fill in.
#
# SOURCED BY (to find callers):  grep -rl 'i18n.sh' scripts/
#   (currently morning-review.sh, weekly-summary.sh, and
#    article-suggestions.sh via the strings they reference).
#
# PROVIDES: the I18N_* variables (one per UI string) — see each line below.
# =============================================================================

I18N_MORNING_TITLE="Logbook — Morning Review"
I18N_REVIEWING_DAYS="(reviewing %d unreviewed days)"
I18N_ACTIVITY_FOR="Activity for %s"
I18N_PLANNED="Planned:"
I18N_SESSIONS="Claude Code Sessions (%d):"
I18N_PRS="Pull Requests (%d):"
I18N_APPROVE="Approve"
I18N_REVIEW_LATER="Review later"
I18N_SKIP="Skip"
I18N_NOTE_PROMPT="Observations / actions? (Enter to skip)"
I18N_CARRY_OVER_LABEL="Carry over:"
I18N_INTENTION_PROMPT="What are you working on today? (Enter to skip)"
I18N_INTENTION_SAVED="Intention saved for %s"
I18N_APPROVED_SAVED="Approved and saved to reviewed/"
I18N_SKIPPED="Skipped %s."
I18N_NO_ACTIVITY="No unreviewed activity found. Skipping review."
I18N_SCANNING="Scanning PRs for %s..."
I18N_SIGNALS_TITLE="Improvement Signals:"
I18N_FLAG_RATE_OK="0 of %d sessions flagged — quiet day is a data state, not an analysis failure."
I18N_FLAG_RATE="%d of %d sessions flagged."
I18N_COMMITTED="Committed daily log"
I18N_PUSHED="Pushed to remote"
I18N_SYNCED="Synced ~/.claude settings"
I18N_AI_INSIGHTS="AI Insights:"
I18N_IMPROVE_REMINDER="Consider running /improve to analyze your recent sessions."
I18N_IMPROVE_RECENT="Last /improve analysis: %s"
I18N_IMPROVE_DONE="/improve already run today (%s)."
I18N_CLAUDE_DIRTY="~/.claude has uncommitted changes — review and commit manually:"
I18N_GH_UNREACHABLE="⚠ GitHub unreachable — PR data will be incomplete in this review."
I18N_WORKER_DEATHS="⚠ %d session analysis worker(s) crashed since the last review — see the logbook.log in the data dir's state directory, recover via 'logbook backfill'."
I18N_FLAG_VERDICT_PROMPT="Flag verdict for %s:"
I18N_FLAG_CORRECT="Flag was right"
I18N_FLAG_WRONG="False positive"
I18N_FLAG_SKIP_ONE="Skip"
I18N_DEFER_EXPIRY="%s will reappear at the next review — drops out of the window in %d day(s)."
I18N_PUSH_FAILED="⚠ Push failed — reports are NOT published to the remote."
I18N_CALIBRATION_WARN="⚠ Flag calibration off band: %d confirmed of %d heuristic fires (%d%%) over 7 days — expected 10–40%%. Check the flag-analysis prompt in the tool's lib."

# Used by weekly-summary.sh
I18N_WEEKLY_WRITTEN="Weekly summary written to: %s"
I18N_WEEKLY_COMMITTED="Committed weekly summary"
# Used by article-suggestions.sh
I18N_ARTICLES_TITLE="Suggested reading:"
I18N_RELEASES_TITLE="Claude / Claude Code releases:"
