# logbook — Architecture

This document describes exactly what happens at each stage, what data flows where, and why. Reading this should be equivalent to reading the code.

---

## 0. Two Roots

Everything below operates across two directories:

- **`TOOL_DIR`** — this repo. Read-only at runtime; nothing here is written by a
  running script. `bin/logbook` resolves it from its own (symlink-followed)
  location and dispatches every command to `scripts/`.
- **`DATA_DIR`** — the user-configured data directory. Every write lands here.
  Resolution order (highest wins): `LOGBOOK_DATA_DIR` env var →
  `~/.config/logbook/config` → `~/.local/share/logbook`.

`scripts/config.sh` is sourced by every script and derives all concrete paths
from `DATA_DIR`: `STATE_DIR` (`.state/`), `DAILY_DIR`, `REVIEWED_DIR`,
`DOCS_DIR`, `WEEKLY_ROOT`, `DATA_README`, `FIXTURES_DIR`, plus helpers
(`portable_date`, `derive_project_name`, `find_sessions_index`).

`install.sh` symlinks the `logbook` CLI into `~/.local/bin`, symlinks the
`improve`/`daily-status` skills into `~/.claude/skills/`, writes the config
file, seeds the data dir (`docs/open-concerns.md`, `docs/watch-items.json`,
README stub, `.gitignore` for `.state/`), and prints the hook block to paste
into `~/.claude/settings.json`. Re-running it upgrades symlinks and overwrites
nothing.

---

## 1. Session Start

**Trigger:** Claude Code `SessionStart` hook calls `logbook session-start`
(absolute path — hooks may not see `~/.local/bin` on PATH).

**Input:** JSON on stdin with `session_id` and `cwd`.

**What it does:**

1. Inserts the session row into SQLite (`db_insert_session`: session_id,
   project, date, branch, `status='in_progress'`).
2. Records `{ started_at, cwd }` keyed by `session_id` in `.state/session-starts.json`.
3. Prunes state entries older than 7 days.
4. Prunes `daily/*.json` files older than **12** days. This is the only place
   daily JSONs are deleted. (12, not less: the morning-review lookback is 10
   days, so a shorter prune would delete intention/reflection/PR data for days
   still awaiting review.)
5. Writes `.state/active-session.json` with `session_id`, `project_name`, `started_at`, `cwd`.
6. Outputs **SQLite tracking instructions** to stdout. Claude sees these as a
   system reminder and, during the session, updates the row's Skill (and
   optionally Name) fields via `sqlite3` commands.

**Output:** New DB row, updated `.state/session-starts.json`,
`.state/active-session.json`, stdout instructions for Claude.

---

## 2. Session End

**Trigger:** Claude Code `SessionEnd` hook calls `logbook session-end` — a tiny
script that reads the hook JSON from stdin, forks
`session-end-worker.sh` into the background, and exits fast (the worker can run
for many seconds).

**Input (worker args):** `session_id`, `transcript_path`, `cwd`.

**What the worker does:**

1. Looks up start time from `.state/session-starts.json`. Falls back to current time if missing.
2. Calculates duration in minutes; sessions with no interaction are deleted, not recorded.
3. Derives project name from `cwd`:
   - If under `$PROJECTS_DIR/`, takes the first path component after it.
   - If under `~/.claude-squad/worktrees/`, extracts repo name from git remote.
   - Fallback: git remote basename, then git toplevel basename, then directory basename.
4. Extracts session metadata from `sessions-index.json`: summary, first prompt, git branch.
5. Detects skill invocation from the first prompt, then reconciles an
   **effective skill**: the DB `skill` column (written live by session
   tracking) or the transcript-derived name as fallback — so a broken
   derivation and a missing live write each cover the other.
6. Links commits produced during the session (by author + time range).
7. Runs `transcript-analyzer.py` on the full transcript. Extracts:
   - `total_turns`, `total_tool_calls`, `tool_errors`, `files_modified_count` — heuristic metrics.
   - `cost_usd` — estimated session cost.
8. Builds session name from summary or first prompt (e.g. `[my-app] Fix auth token validation (45m, $2.30)`).
9. **Heuristic flag detection** — deliberately noisy; the LLM pass below can clear false positives:
   - High error rate: tool errors >= 3 AND error rate > 30%.
   - Spinning wheels: 5+ turns, 0 files modified, 0 commits (skipped for
     read-only skills like review-pr, analyze-ticket, investigate-ci).
   - Test failures: `tests_passed=false`.
   - Thrashing: turns >= 20 AND files modified <= 1.
   - High cost: >= $15.
   The pre-LLM verdict is preserved in `heuristic_flagged` (the LLM may clear
   `flagged` but never touches this — it feeds the calibration watchdog).
10. Runs condensed transcript extraction via `transcript-analyzer.py --condensed`.
11. **LLM narrative** (for ALL sessions with a transcript) — sends the
    condensed transcript to an LLM with a structured prompt; returns 5-section
    markdown: Goal, Approach, Outcome, Friction, Improvement Signal. Model
    gate: haiku by default, a stronger model for substantive sessions
    (>= 20 turns or >= $5); `NARRATIVE_MODEL` overrides.
12. **Narrative cross-check** (`lib/narrative-check.sh`, deterministic) —
    validates the narrative against known facts (cited commit hashes must
    exist, "nothing shipped" must match commit counts, …). Sets
    `narrative_confidence` (`high`/`low`) and `narrative_issues`; a `low`
    narrative renders as `⚠ unverified` in the review.
13. **LLM flag analysis** (for flagged sessions only) — sends the condensed
    transcript to a stronger model (`FLAG_ANALYSIS_MODEL`) for adjudication.
    Extracts `issue` and `suggestion`; clears the flag when the heuristics
    were misleading.
14. **Meta-cost capture** — both LLM calls run with `--output-format json`;
    their `total_cost_usd` is summed into the `meta_cost` column, so the
    pipeline's own spend is measured, not invisible.
15. **PII scrub** (`lib/pii-scrub.sh`) — applied to everything recorded, at
    record time.
16. **Writes everything to SQLite**: metrics via `db_update_metrics`, name,
    description (LLM narrative), branch, skill, narrative/flag columns.
17. Updates `.state/active-session.json` with metrics and analysis.
18. Refreshes the article-suggestions cache if stale (>12h).
19. Cleans up the session-start state entry from `.state/session-starts.json`.

**Output:** SQLite row fully populated with name, description, metrics, flags, and analysis.

A **worker-death watchdog** in the morning review compares session-end fires
against completed worker runs, so a crashed worker is surfaced instead of
silently losing a day's rows; `logbook backfill` re-runs the worker on sessions
left with missing metrics.

---

## 3. Morning Review

**Trigger:** `logbook morning-review`, run however the user launches their day
(shell, tmuxinator, cron — the tool doesn't care).

**Idempotency:** Checks `.state/last-review-date`. If it matches today, exits immediately.

### Step 1 — Find Unreviewed Days

Reads all sessions from the SQLite database for the last 10 days. Groups by date. For each date:
- Skips weekends (Saturday/Sunday).
- Skips if `reviewed/<date>.md` exists (already approved or skipped).
- Includes if there are sessions for that date that haven't been reviewed yet.

Sorts results chronologically (oldest first).

### Step 2 — Enrich with Git Data

For each unreviewed day, runs `scan_git_activity` and `scan_pull_requests` (from
`git-activity.sh`) across all repos under `$PROJECTS_DIR/` (unset → a small
fallback list in `.state/fallback-repos`). Writes `git_activity` (map of repo
to commit list) and `pull_requests` (array) into the daily JSON.

### Step 3 — Display

For each unreviewed day, shows a TUI screen with:

1. **Intention** — what was planned for that day (from daily JSON, if set).
2. **Sessions** — from SQLite. Each line shows: project name, duration, cost,
   description. Flagged sessions render orange with their issue; so do
   deterministic signals (`outcome` ∈ {partial, abandoned, wrong_approach},
   `narrative_confidence='low'`) — the review's intelligence does not depend
   on the LLM flag alone. Flag verdicts the user gives here land in
   `flag_feedback` (labeled data for the flag calibration corpus).
3. **Pull Requests** — from daily JSON: state, number, title, repo.

### Step 4 — User Action

Three choices:

**Approve:**
1. Prompts for a quick reflection note. Stored in `daily/<date>.json` under `.reflection.note`.
2. Injects article suggestions into the daily JSON.
3. Runs `daily-report.sh` which generates a markdown report into `reviewed/<date>.md`.

**Review later:** Does nothing. The day will appear again tomorrow.

**Skip:** Creates a minimal `reviewed/<date>.md` with just `"# Skipped — <date>"` so the day won't reappear.

### Step 5 — Daily Intention

Shows the last reflection note as carry-over context (reads from `daily/*.json`, most recent first). Prompts for today's intention. Writes it to `daily/<today>.json`.

### Step 6 — Commit and Push

Only when `DATA_DIR` is a git repo (otherwise files are just written). Collects:
- `daily/<today>.json` (intention).
- For each reviewed date: `daily/<date>.json` (enriched with git/PR data + reflection), `reviewed/<date>.md` (if approved).

Stages, commits with message `"log: daily activity for <today>"`, pushes. The
DB is never committed.

### Step 7 — Open in Browser

If push succeeded and any days were approved, opens each `reviewed/<date>.md`
in the browser. The blob URL is derived from the data repo's `origin` remote;
non-GitHub or missing remote → this step is skipped silently.

### Step 8 — Monday ~/.claude Check

On Mondays, if `~/.claude/` has uncommitted changes, shows `git status --short` and reminds you to review and commit them manually. Does **not** auto-commit (a blanket `git add -A` would sweep unrelated/in-progress changes into an unattended push); `/improve` commits `~/.claude` explicitly when it changes settings.

### Step 9 — Watch-Item Evidence

Runs `watch-report.sh` (see §5) and renders it, so open-concern metrics are in
front of the user right before the /improve step. A failed report renders an
explicit warning, never a silent skip.

### Step 10 — /improve Reminder

`/improve` is run each morning right after the review, so this shows a reminder unless it has already been run today (in which case it shows a quiet "already run today" line).

### Step 11 — Mark Done

Writes today's date to `.state/last-review-date`.

---

## 4. Markdown Report Generation

**Script:** `scripts/lib/daily-report.sh` (also what `logbook status` runs for today).

**Input:** Date and output directory (defaults to `reviewed/`).

**Reads:**
- SQLite session data — sessions for the date, including flags and analysis.
- `daily/<date>.json` for non-session data (intention, reflection, articles).

**Generates sections:**

1. **Plan** — the day's intention (from daily JSON).
2. **Reflection** — the user's note (from daily JSON, written during approval step).
3. **Claude Code Sessions** — from SQLite. One line per session: project, duration, cost, description. Highlights flagged sessions. Day totals at the bottom.
4. **Improvement Signals** — per-session signals extracted from the narratives, for all sessions (not just flagged).
5. **Claude / Claude Code Releases** and **Suggested Reading** — from daily JSON.

> PR data is captured in the daily JSON and shown in the TUI, but never written
> to the committed markdown — the data repo may publish to a remote.

**Output:** `<output_dir>/<date>.md`

---

## 5. Watch-Item Evidence (intervention efficacy)

**Script:** `scripts/watch-report.sh` (+ `scripts/lib/watch-metrics.sh`, registry `$DATA_DIR/docs/watch-items.json`)

Read-only. For each registered watch item it computes the *measurable half* of that
concern's close/reopen condition — confirmed-flag rate, hook block-clear count,
outcome-pattern count, low-confidence-narrative count — over the last N **windows**
(a window = a date with sessions that also has a `reviewed/<date>.md` file), and prints
it next to the item's threshold. Items with a recorded `intervention` render an
honest before/after around the intervention date. It emits **evidence, never a
verdict**: no CLOSE/REOPEN/"evidence supports" string. Items with `metric: null`
render as a visible "no computable metric registered" gap. A missing or
format-broken hook audit log renders `⚠ metric source unreadable`, never a false
`0`. Surfaced in the morning review (§3 Step 9) and readable by `/improve`
(`--report`: plain text + spot-check rows). Registry is hand-written; the tool
never edits `open-concerns.md`, never commits.

---

## 6. Hook Health

**Script:** `scripts/hook-report.sh`

Read-only telemetry over the user's guard hooks. Reads three machine-wide
sources, all env-overridable: `~/.claude/logs/hook-fires.log`
(`HOOK_FIRES_LOG`), `~/.claude/logs/scope-expansion-reset.log`
(`SCOPE_RESET_LOG`), and the `~/.claude/hooks/` roster (`HOOKS_DIR`). Joins
fires against the sessions DB to report, per hook: fire counts and sub-classes,
session/project clusters, overlap with flagged sessions, the disarm tally, and
**inert** hooks (instrumented, zero fires ever). Like the watch report it emits
evidence only — `⚠ your call:` lines mark the judgment tasks, and any
prune/fix decision stays with the user. On a machine without hook telemetry it
prints "no telemetry yet" and exits 0, so a fresh install is safe.

---

## 7. Weekly Summary

**Script:** `scripts/weekly-summary.sh`, via `logbook weekly-summary [monday friday]`.

Manual (not wired into the morning review). With no args it summarises the
*current* Mon–Fri week; pass explicit dates for a past week. Groups the week's
sessions and daily reflections, writes
`$WEEKLY_ROOT/<year>/<mm-mon>/<year>_<mon>_<fri>.md`, inserts a link under the
`## Logs` section of the data-dir README, and auto-commits both (git repo
gate, same as the review).

---

## 8. Folder Contract (data dir)

| Folder | Contains | Lifecycle |
|--------|----------|-----------|
| `daily/` | JSON only | Created by session/review scripts. Intention, reflection, git/PR data, articles — no session records. Pruned after 12 days by session-start. |
| `reviewed/` | Markdown only | Generated on morning review approval. Permanent. |
| `docs/` | `open-concerns.md`, `watch-items.json` | Hand-maintained (via /improve, under approval). Seeded by install. |
| `<year>/<mm-mon>/` | Weekly summaries | Written by `weekly-summary`; indexed in the data README. |
| `eval/fixtures/` | Private flag-analysis corpus | Tracked in the (private) data repo; grown by `logbook freeze-fixture`; never in the tool repo. |
| `.state/` | Runtime state | Gitignored. SQLite DB, logs, caches, idempotency stamps. |

The tool repo contributes only code (`scripts/`, `bin/`, `skills/`, `agents/`)
and is never written to at runtime.

---

## 9. Data Model

### SQLite = source of truth for session data

**SQLite database** (`$STATE_DIR/sessions.db`, WAL mode) contains **all** session data:

| Column | Type | Content |
|---|---|---|
| session_id | TEXT UNIQUE | UUID |
| name | TEXT | `[PROJECT] description` |
| project | TEXT | Project name |
| date | TEXT | Session date (YYYY-MM-DD) |
| duration | INTEGER | Minutes |
| cost | REAL | USD (user's session, from the transcript) |
| branch | TEXT | Git branch |
| skill | TEXT | Skill invoked (if any) |
| status | TEXT | `in_progress` / `done` |
| turns | INTEGER | Conversation turns |
| tool_calls | INTEGER | Total tool invocations |
| tool_errors | INTEGER | Error count |
| files_modified | INTEGER | Files changed |
| flagged | INTEGER | 1 if the session met flag criteria (post-LLM verdict) |
| heuristic_flagged | INTEGER | Pre-LLM heuristic verdict — the LLM never touches this |
| flag_feedback | TEXT | User's morning-review verdict on a flag (`correct`/`wrong`) |
| issue | TEXT | LLM analysis of the problem (if flagged) |
| suggestion | TEXT | LLM recommendation for improvement (if flagged) |
| description | TEXT | LLM narrative (Goal/Approach/Outcome/Friction/Improvement Signal) |
| narrative_confidence | TEXT | `high`/`low` — deterministic cross-check verdict |
| narrative_issues | TEXT | The contradictions behind a `low` verdict |
| meta_cost | REAL | The pipeline's own LLM spend on this session |
| first_prompt | TEXT | First 500 chars of the user's opening prompt |
| task_type | TEXT | LLM-classified: review / bugfix / feature / investigation / refactor / config / other |
| outcome | TEXT | LLM-classified: success / partial / abandoned / wrong_approach |
| created_at | TEXT | Insertion timestamp |

Row created by `session-start.sh` (via `db_insert_session`), enriched by Claude
during the session (via `sqlite3` UPDATE commands), and completed by the
session-end worker.

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
  "claude_releases": [
    { "title": "Claude Code vX.Y.Z", "url": "https://...", "published": "..." }
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
