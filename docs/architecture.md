# Log Book — Architecture

This document describes exactly what happens at each stage, what data flows where, and why. Reading this should be equivalent to reading the code.

---

## 1. Session Start

**Trigger:** Claude Code `SessionStart` hook calls `scripts/session-start.sh`.

**Input:** JSON on stdin with `session_id` and `cwd`.

**What it does:**

1. Records `{ started_at, cwd }` keyed by `session_id` in `.state/session-starts.json`.
2. Prunes state entries older than 7 days.
3. Prunes `daily/*.json` files older than 8 days. This is the only place daily JSONs are deleted.
4. Writes `.state/active-session.json` with `session_id`, `project_name`, `started_at`, `cwd`.
5. Outputs **SQLite tracking instructions** to stdout. Claude sees these as a system reminder and:
   - During the session, updates the SQLite row's Description (appending narrative of work done), Name (concise summary), Branch, and Skill fields via `sqlite3` commands.

**Output:** Updated `.state/session-starts.json`, `.state/active-session.json`, stdout instructions for Claude.

---

## 2. Session End

**Trigger:** Claude Code `SessionEnd` hook calls `scripts/session-end.sh`.

**Input:** JSON on stdin with `session_id`, `transcript_path`, `cwd`, `reason`.

**What it does:**

1. Looks up start time from `.state/session-starts.json`. Falls back to current time if missing.
2. Calculates duration in minutes.
3. Derives project name from `cwd`:
   - If under `$PROJECTS_DIR/`, takes the first path component after it.
   - If under `~/.claude-squad/worktrees/`, extracts repo name from git remote.
   - Fallback: git remote basename, then git toplevel basename, then directory basename.
4. Extracts session metadata from `sessions-index.json`: summary, first prompt, git branch.
5. Detects skill invocation from first prompt pattern.
6. Links commits produced during the session (by author + time range).
7. Runs `transcript-analyzer.py` on the full transcript. Extracts:
   - `total_turns`, `total_tool_calls`, `tool_errors`, `files_modified_count` — heuristic metrics.
   - `cost_usd` — estimated session cost.
8. Builds session name from summary or first prompt (e.g. `[my-app] Fix auth token validation (45m, $2.30)`).
9. **Flag Detection** — analyzes metrics for problematic patterns:
   - High error rate: if tool errors >= 3 AND error rate > 30%.
   - Spinning wheels: 5+ turns, 0 files modified, 0 commits (skipped for read-only skills like review-pr, analyze-ticket).
   - Test failures: if `tests_passed=false`.
   - Thrashing: turns >= 20 AND files modified <= 1.
10. Runs condensed transcript extraction via `transcript-analyzer.py --condensed`.
11. **LLM Narrative** (for ALL sessions with a transcript) — sends condensed transcript to Haiku with a structured prompt. Returns 5-section markdown: Goal, Approach, Outcome, Friction, Improvement Signal.
12. **LLM Analysis** (for flagged sessions only) — sends condensed transcript to Sonnet for deeper analysis. Extracts `issue` and `suggestion`. If LLM determines flags were misleading, clears the flag.
13. **Writes everything to SQLite**: metrics via `db_update_metrics`, name via `db_update_field`, description (LLM narrative) via `db_update_description`, branch and skill via `db_update_field`.
14. Updates `.state/active-session.json` with metrics and analysis.
15. Refreshes article suggestions cache if stale (>12h).
16. Cleans up the session-start state entry from `.state/session-starts.json`.

**Output:** Updated `.state/active-session.json`, SQLite row fully populated with name, description, metrics, flags, and analysis.

---

## 4. Morning Review

**Trigger:** `scripts/morning-review.sh`, run via tmuxinator `on_project_start`.

**Idempotency:** Checks `.state/last-review-date`. If it matches today, exits immediately.

### Step 1 — Find Unreviewed Days

Reads all sessions from the SQLite database for the last 10 days. Groups by date. For each date:
- Skips weekends (Saturday/Sunday).
- Skips if `reviewed/<date>.md` exists (already approved or skipped).
- Includes if there are sessions for that date that haven't been reviewed yet.

Sorts results chronologically (oldest first).

### Step 2 — Enrich with Git Data

For each unreviewed day, runs `scan_git_activity` and `scan_pull_requests` (from `git-activity.sh`) across all repos under `$PROJECTS_DIR/`. Writes `git_activity` (map of repo to commit list) and `pull_requests` (array) into the daily JSON.

### Step 3 — Display

For each unreviewed day, shows a TUI screen with:

1. **Intention** — what was planned for that day (from daily JSON, if set).
2. **Sessions** — from SQLite. Each line shows: project name, duration, cost, description.
3. **Pull Requests** — from daily JSON: state, number, title, repo.

### Step 4 — User Action

Three choices:

**Approve:**
1. Prompts for a quick reflection note. Stored in `daily/<date>.json` under `.reflection.note`.
2. Injects article suggestions into the daily JSON.
3. Runs `daily-report.sh` which generates a markdown report into `reviewed/<date>.md`.

**Review later:** Does nothing. The day will appear again tomorrow.

**Skip:** Creates a minimal `reviewed/<date>.md` with just `"# Skipped — <date>"` so the day won't reappear.

### Step 5 — Monday Weekly Digest

On Mondays only, sources `weekly-digest.sh` which:

1. Reads sessions for the previous Mon-Fri from SQLite.
2. Computes week stats directly from session properties: total sessions, projects, cost, duration.
3. Sends session data to Claude for AI synthesis via `weekly-synthesis.sh`. The LLM returns: `week_recap` (narrative), `insights` (specific patterns), `what_worked`, `watch_next_week`.
4. Displays all of this in the TUI.

### Step 6 — Daily Intention

Shows the last reflection note as carry-over context (reads from `daily/*.json`, most recent first). Prompts for today's intention. Writes it to `daily/<today>.json`.

### Step 7 — Commit and Push

Collects files to commit:
- `daily/<today>.json` (intention).
- For each reviewed date: `daily/<date>.json` (enriched with git/PR data + reflection), `reviewed/<date>.md` (if approved).

Stages, commits with message `"log: daily activity for <today>"`, pushes.

### Step 8 — Open in Browser

If push succeeded and any days were approved, opens each `reviewed/<date>.md` on GitHub in the browser.

### Step 9 — Monday ~/.claude Check

On Mondays, if `~/.claude/` has uncommitted changes, shows `git status --short` and reminds you to review and commit them manually. Does **not** auto-commit (a blanket `git add -A` would sweep unrelated/in-progress changes into an unattended push); `/improve` commits `~/.claude` explicitly when it changes settings.

### Step 10 — /improve Reminder

`/improve` is run each morning right after the review, so this shows a reminder unless it has already been run today (in which case it shows a quiet "already run today" line).

### Step 11 — Mark Done

Writes today's date to `.state/last-review-date`.

---

## 5. Markdown Report Generation

**Script:** `scripts/lib/daily-report.sh`

**Input:** Date and output directory (defaults to `reviewed/`).

**Reads:** 
- SQLite session data — sessions for the date, including flags and analysis.
- `daily/<date>.json` for non-session data (intention, reflection, articles).

**Generates sections:**

1. **Plan** — the day's intention (from daily JSON).
2. **Reflection** — the user's note (from daily JSON, written during approval step).
3. **Claude Code Sessions** — from SQLite. One line per session: project, duration, cost, description. Highlights flagged sessions. Day totals at the bottom.
4. **Suggested Reading** — from daily JSON, articles with descriptions.

> PR data is captured in the daily JSON and shown in the TUI, but never written to the committed markdown — this repo publishes to a public remote.

**Output:** `<output_dir>/<date>.md`

---

## 5b. Watch-Item Evidence (intervention efficacy)

**Script:** `scripts/watch-report.sh` (+ `scripts/lib/watch-metrics.sh`, registry `docs/watch-items.json`)

Read-only. For each registered watch item it computes the *measurable half* of that
concern's close/reopen condition — confirmed-flag rate, hook block-clear count,
outcome-pattern count, low-confidence-narrative count — over the last N **windows**
(a window = a date with sessions that also has a `reviewed/<date>.md` file), and prints
it next to the item's threshold. It emits **evidence, never a verdict**: no
CLOSE/REOPEN/"evidence supports" string. Items with `metric: null` render as a visible
"no computable metric registered" gap. A missing or format-broken hook audit log renders
`⚠ metric source unreadable`, never a false `0`. Surfaced in the morning review
(§4, before the /improve reminder) and readable by `/improve`. Registry is hand-written;
the tool never edits `open-concerns.md`, never commits.

---

## 6. Folder Contract

| Folder | Contains | Lifecycle |
|--------|----------|-----------|
| `daily/` | JSON only | Created by morning review (enriched with git/PR data). Contains intention, reflection, articles — no session records. Pruned after 8 days by session-start. |
| `reviewed/` | Markdown only | Generated on morning review approval. Permanent. |
| `.state/` | Runtime state | Gitignored. Session timestamps, active session state, article cache, idempotency guards. |
| `scripts/` | All code | Bash scripts + Python transcript analyzer. |

---

## 7. Data Model

### SQLite = source of truth for session data

**SQLite database** (`.state/sessions.db`, WAL mode) contains **all** session data:

| Column | Type | Content |
|---|---|---|
| session_id | TEXT UNIQUE | UUID |
| name | TEXT | `[PROJECT] description` |
| project | TEXT | Project name |
| date | TEXT | Session date (YYYY-MM-DD) |
| duration | INTEGER | Minutes |
| cost | REAL | USD |
| branch | TEXT | Git branch |
| skill | TEXT | Skill invoked (if any) |
| status | TEXT | `in_progress` / `done` |
| turns | INTEGER | Conversation turns |
| tool_calls | INTEGER | Total tool invocations |
| tool_errors | INTEGER | Error count |
| files_modified | INTEGER | Files changed |
| flagged | INTEGER | 1 if session met any flag criteria |
| issue | TEXT | LLM analysis of the problem (if flagged) |
| suggestion | TEXT | LLM recommendation for improvement (if flagged) |
| description | TEXT | Claude's narrative summary of the session |
| created_at | TEXT | Insertion timestamp |
| first_prompt | TEXT | First 500 chars of the user's opening prompt |
| task_type | TEXT | LLM-classified: review / bugfix / feature / investigation / refactor / config / other |
| outcome | TEXT | LLM-classified: success / partial / abandoned / wrong_approach |

Row created by `session-start.sh` (via `db_insert_session`), enriched by Claude during the session (via `sqlite3` UPDATE commands), and completed by `session-end.sh` (via `db_update_metrics`).

### State files

**`.state/active-session.json`** — tracks the current session for session-end.sh:

```json
{
  "session_id": "uuid",
  "project_name": "my-app",
  "started_at": "2026-03-30T09:00:00Z",
  "cwd": "/home/you/projects/my-app",
  "git_branch": "feat/something"
}
```

Written by `session-start.sh`. Consumed by `session-end.sh` for description retrieval.

**`.state/session-starts.json`** — maps `session_id` to `{ started_at, cwd }` for duration calculation. Pruned after 7 days.

### Daily JSON (non-session data only)

```json
{
  "date": "2026-03-16",
  "intention": "Bug fixes, AI use improvements",
  "git_activity": {
    "my-app": [
      { "message": "fix: JWT validation", "author": "you", "hash": "a1b2c3d" }
    ]
  },
  "pull_requests": [
    {
      "number": 42,
      "title": "Fix auth middleware",
      "state": "MERGED",
      "repo": "my-app",
      "url": "<private>"
    }
  ],
  "suggested_articles": [
    { "title": "Article title", "url": "https://...", "source_domain": "reddit.com" }
  ],
  "reflection": {
    "note": "Auth refactor went smoothly"
  }
}
```

There is no `sessions` array in the daily JSON. All session data lives in SQLite.
