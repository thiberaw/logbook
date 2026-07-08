# scripts/ — how the code fits together

A reading guide for the shell scripts in this folder. Each `.sh` file also has a
header block explaining *what it is* and *how to read it*; this page is the map of
how they connect. For the data-flow narrative (what happens at each step), see
[`../docs/architecture.md`](../docs/architecture.md).

## Two kinds of files

- **Entry points / runnable scripts** — started by something external (a Claude
  Code hook, tmuxinator, or you on the command line). They *do* things.
- **Libraries** (everything in `lib/`, plus `config.sh`) — `source`d by the
  runnable scripts to borrow their functions/variables. They are **not** run on
  their own. (Two exceptions are runnable *and* sourced where noted below.)

## Entry points — start reading here

| File | Triggered by | What it does |
|------|--------------|--------------|
| `session-start.sh` | Claude Code **SessionStart** hook | Insert a new "in progress" row in the database; prune old daily files; print the session-tracking reminder. |
| `session-end.sh` | Claude Code **SessionEnd** hook | Tiny: reads the hook's JSON from stdin and launches `session-end-worker.sh` in the background, then exits fast. |
| `session-end-worker.sh` | forked by `session-end.sh` | **The heavy lifter.** Extracts metrics from the transcript, asks an LLM for a narrative, runs the flag heuristics, writes everything to the database. Start here to understand how a session is scored/flagged. |
| `morning-review.sh` | tmuxinator at project open | The interactive "good morning" review TUI. Walks unreviewed days, takes your approval + reflection, generates the report, commits & pushes. |
| `weekly-summary.sh` | manual / scheduled | Standalone weekly report. |
| `backfill-sessions.sh` | manual | Re-runs the worker on sessions that ended up with 0 turns (e.g. after a crash). |
| `watch-report.sh` | morning-review.sh (TUI) + /improve (`--report`) | Read-only evidence reporter for open-concerns watch items; computes metrics over windows. Default = colour-coded TUI sorted attention-first; `--report` = plain text + spot-check rows for /improve. |

## Who calls / sources whom

```
session-start.sh ──sources──> config.sh, lib/logging.sh, lib/sessions-db.sh

session-end.sh ──sources──> config.sh, lib/logging.sh, lib/sessions-db.sh
      │
      └─runs in background─> session-end-worker.sh
                                  ├─sources─> config.sh, lib/logging.sh,
                                  │           lib/sessions-db.sh, lib/session-utils.sh,
                                  │           lib/flag-analysis.sh, lib/narrative-check.sh
                                  └─runs────> lib/fetch-articles.sh

morning-review.sh ──sources──> config.sh, lib/logging.sh, lib/git-activity.sh,
      │                        lib/i18n.sh, lib/article-suggestions.sh,
      │                        lib/sessions-db.sh, lib/session-utils.sh
      ├─runs──> lib/fetch-articles.sh        (refresh the article cache)
      └─runs──> lib/daily-report.sh          (render reviewed/<date>.md)

backfill-sessions.sh ──runs──> session-end-worker.sh
weekly-summary.sh ──sources──> config.sh, lib/i18n.sh, lib/sessions-db.sh, lib/session-utils.sh
```

`config.sh` is sourced by essentially everything — read it first.

## Libraries (in `lib/`)

| File | Provides |
|------|----------|
| `config.sh` *(in `scripts/`, not `lib/`)* | All paths (`STATE_DIR`, `DAILY_DIR`, …) + helpers like `portable_date`, `derive_project_name`. Sourced first by everyone. |
| `logging.sh` | `log_info` / `log_warn` / `log_error` → the log file. |
| `sessions-db.sh` | The SQLite layer: `init_sessions_db`, `db_insert_session`, `db_update_metrics`, `db_get_field`, the query helpers. All DB access goes through here. |
| `session-utils.sh` | Rendering helpers (`render_session_list`, `render_improvement_signals*`, `get_day_totals`) + narrative JSON handling. |
| `flag-analysis.sh` | `build_flag_prompt` / `extract_flag_json` — the single source for the sonnet flag-analysis prompt (shared with the golden test). |
| `narrative-check.sh` | `validate_narrative` — cross-checks the LLM narrative against the deterministic metrics to catch confabulation (sets `narrative_confidence`). |
| `git-activity.sh` | `scan_pull_requests` — find a day's PRs via the `gh` CLI. |
| `i18n.sh` | The `I18N_*` UI strings (French default, English fallback). |
| `article-suggestions.sh` | Pick + write the "suggested reading" into a day's JSON. |
| `fetch-articles.sh` | Fetch article candidates from feeds (also runnable standalone). |
| `daily-report.sh` | Render `reviewed/<date>.md` from the DB + daily JSON (also runnable standalone). |
| `watch-metrics.sh` | Window resolver + one pure-read metric fn per watch item. |

## Where the data lives

- **`.state/sessions.db`** — the SQLite database, the canonical session record (gitignored).
- **`daily/<date>.json`** — per-day reflection metadata (intention, articles, PRs).
- **`reviewed/<date>.md`** — the committed morning-review output.
- **`docs/watch-items.json`** — registry of watch items for evidence reporting (maintained by the `/improve` loop under approval, never auto-populated by the reporter).

## Suggested reading order for a newcomer

1. `config.sh` — the paths and shared vocabulary.
2. `lib/sessions-db.sh` — the database shape (the table schema is here).
3. `session-start.sh` → `session-end.sh` → `session-end-worker.sh` — a session's life.
4. `morning-review.sh` + `lib/daily-report.sh` — how a day gets reviewed and reported.
