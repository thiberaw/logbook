---
name: improve
description: Analyze recent Claude Code sessions through 5 lenses (config, retrospective, awareness, wide-view, skill-audit) and apply improvements. Reads session data from local SQLite database. Use when reviewing recent Claude Code sessions, after a morning review, or when invoked as /improve.
---

# /improve — Analyze Sessions & Apply Improvements

Read session data from local SQLite database, analyze through 5 lenses, and apply improvements to Claude Code configuration, workflows, and tooling.

## Failure modes

- Apply a change during the read-only phase → mutates config before user approval. Guard: phases 1–2 are read-only; no Edit/Write/commit before Step 7.
- Fabricate a finding not grounded in session data → acts on noise. Guard: every finding cites session evidence (DB row / reviewed report).
- Apply an item the user didn't name → scope creep into config. Guard: apply only items the user explicitly approves in Step 7.

## Phases

This skill runs in three strict phases:

1. **READ-ONLY data gathering** (steps 1–6) — query DB, read files, compute findings. Do not Edit, Write, or run commands that modify state.
2. **Present findings** (step 7) — show all proposed changes. Wait for explicit approval. Do not skip ahead to implementation, even if a change seems obviously good.
3. **Apply approved changes** (step 8) — only after the user names which items to apply.

> If you reach for Edit, Write, or `git commit` before step 7, stop. The change belongs in the findings list, not in the working tree.

## Step 0 — hard guard

```bash
command -v logbook >/dev/null || { echo "logbook not on PATH — run the tool's install.sh"; exit 1; }
```

Every path below resolves through the `logbook` CLI. Without this guard,
`$(logbook path …)` expands empty and the workflow proceeds against broken
paths instead of failing loudly. If `open-concerns.md` or `watch-items.json`
is missing (fresh install, deleted), treat it as empty — note it, don't fail.

## Data sources

- **SQLite database**: `$(logbook path db)`. Each session row has: Name, Project, Date, Duration, Cost, Branch, Skill, Description, Turns, Tool_Calls, Tool_Errors, Files_Modified, Session ID, Flagged (0/1), Issue (text), Suggestion (text). **Primary input for metrics and flagged session analysis.**
- **Reviewed daily reports**: `$(logbook path reviewed)/*.md` — morning-review output with curated per-session analysis. **Primary input for improvement signals.** Each file contains:
  - `## Reflection` — user's own notes on the day
  - `## Claude Code Sessions` — session summaries with flagged issues (indented `>` blocks)
  - `## Improvement Signals` — actionable suggestions for ALL sessions (not just flagged ones), including non-flagged sessions that the database `suggestion` field misses. Each signal has a project, description, and often a concrete `→` recommendation.
  - `## Suggested Reading` — curated articles
- **Daily logs**: `$(logbook path daily)/*.json` — non-session data: `intention`, `reflection.note`, `suggested_articles`
- **Open concerns**: `$(logbook path concerns)` — ongoing evaluations, architectural questions, and improvement ideas that need evidence before deciding. Each concern has a friction log and daily observations. /improve checks these against recent session data and appends new evidence.
- **State**: `$(logbook path state)/last-improve-date` — date of last run
- **Article fetcher**: `logbook fetch-articles` refreshes the cache; the script lives in the tool repo at `scripts/lib/fetch-articles.sh` — read it only if the awareness lens finds article quality issues

**Read discipline:** read data files with the Read tool on their **real paths** — for large files (e.g. `open-concerns.md`), grep the section outline first, then Read with offset/limit. Never read content through Bash `cat` or a tool-result cache path ("Output too large, saved to <path>") — those reads do not satisfy the Edit precondition and waste a failed-Edit round-trip. Pre-read the files you will later edit (`open-concerns.md`, `watch-items.json`, `.audit-cursor`) during data gathering.

## Process

### 1. Query flagged sessions

Read `$(logbook path state)/last-improve-date` to get the window start (or default to 7 days ago).

Query the SQLite database for flagged sessions:
```bash
sqlite3 -json $(logbook path db) \
  "SELECT * FROM sessions WHERE flagged = 1 AND date >= '$START_DATE'"
```

For each flagged session, read:
- `issue`, `suggestion` — the LLM-generated analysis
- `turns`, `tool_calls`, `tool_errors`, `cost`, `duration` — metrics
- `project`, `skill`, `name`, `description` — context

This gives you specific, evidence-based findings for every problematic session.

### 2. Check previous run

Read `$(logbook path state)/last-improve-date`. Focus analysis on sessions since then (or last 7 days if no previous run).

### 3. Gather all session data (single pass)

Fetch all sessions in the window:
```bash
sqlite3 -json $(logbook path db) \
  "SELECT * FROM sessions WHERE date >= '$START_DATE'"
```

From each session, extract:
- `Name`, `Description` — what was done
- `Project`, `Skill`, `Branch` — context
- `Duration`, `Cost`, `Turns`, `Tool Calls`, `Tool Errors`, `Files Modified` — metrics
- `Flagged`, `Issue`, `Suggestion` — analysis

Read reviewed daily reports for dates in the window only — files where `YYYY-MM-DD >= $START_DATE` (`$(logbook path reviewed)/YYYY-MM-DD.md`). Files before `last-improve-date` have already been processed in previous runs. Extract:
- **Improvement Signals** — the full list, including signals from non-flagged sessions. These are often more specific and actionable than the database `suggestion` field (e.g., "add reusable test pattern for auth flows", "document tinymce event-detection pattern"). Cross-reference with database suggestions to get the complete picture.
- **Reflection** — the user's own notes, which may highlight priorities or concerns not captured in session data.
- **Flagged session quotes** (indented `>` blocks under sessions) — verify these match the database `issue` field; the reviewed file may have additional context.

From daily JSON files (`$(logbook path daily)/*.json`), extract: `suggested_articles`, `reflection.note`.

For skill-audit lens: read every `~/.claude/skills/*/SKILL.md` and list any bundled reference files per skill.

Compute aggregate stats:
- Total sessions, total cost, total duration
- Flagged count and flagged percentage
- Unique suggestions from flagged analysis comments (deduplicated)
- Skill usage distribution (from `skill:X` labels)
- Cost by project (from parsed titles)
- Cost per turn (total cost / total turns) — flag if > $1.00 average

### 4. Read current setup (scoped)

Only read config files relevant to patterns found in steps 1-3:
- Always read: `~/.claude/CLAUDE.md`, `~/.claude/settings.json` (hooks section)
- Only if skill gaps found: `ls ~/.claude/skills/`
- Only for projects that appeared in sessions: project-level `CLAUDE.md`

### 5. Check open concerns

Read `$(logbook path concerns)`. For each concern:
- Check whether recent session data provides new evidence (positive or negative)
- Append dated observations under the concern's `### Daily observations` section
- If enough evidence has accumulated to make a decision, flag it in the findings (step 6)

This step feeds into the lenses — concerns with new evidence may surface as config, retrospective, or wide-view findings.

**Read the computed watch evidence first.** Run `logbook watch-report --report` and read its output as the computed half of each registered watch item — the per-window numbers and the `rows (spot-check candidates)`. Use it so you do NOT re-derive numbers the metrics already compute (a measured A/B cut this step's redundant DB queries by ~75%, ~35% cheaper). It does NOT replace the rest of this step:
- **Still read `open-concerns.md`** for each item's close/reopen wording and for the `metric: null` items the report marks "not yet measured" — their evidence and conditions live only there.
- **Still spot-check the rows.** The report's number is evidence, NOT a verified verdict: treat each `⚠ your call:` line as a real task and confirm the rows against the session record before concluding. (In that A/B, the report-fed arm trusted a count and missed a false positive the manual arm caught.) The report is evidence only — the close/reopen decision stays with you and the user.

**Read the hook-health evidence too.** Run `logbook hook-report` — per-hook telemetry from `hook-fires.log` (fire counts, session/project clusters, flagged-session overlap, inert hooks, disarm tally). Evidence only: it emits no verdicts. Treat each `⚠ your call:` line as a judgment task; any hook prune/fix proposal it motivates belongs in the findings list (step 7), never applied inline.

**Reconcile watch-items.json.** For any concern opened or closed in `open-concerns.md` since the last run, add or remove its entry in `$(logbook path watch)` (use `metric: null` if no metric fits yet). The watch-report tool only reports on registered items — an unregistered concern is silently uncovered.

### 6. Apply 5 analysis lenses

Read `references/lenses.md` for the lens definitions, graceful-degradation rules, and per-lens output expectations. Run all 5 lenses over the gathered data — each produces 0–1 items. Target 2–4 total items per run.

The lenses are: **config**, **retrospective**, **awareness**, **wide-view**, **skill-audit**. The skill-audit lens additionally consults `references/skill-audit-rubric.md` for scoring criteria.

### 6b. Mid-flow Q&A

If the user asks a clarifying or explanatory question during the analysis (e.g. "how does cost work?", "what does flagged mean?", "why was this session flagged?"), answer concisely (≤200 words) from memory or the data already loaded. Do NOT run additional `sqlite3` queries, build new tables, or analyze sessions beyond the current window unless the user explicitly says "show me the data", "run that analysis", or names a specific query. Resume the workflow after answering.

> **Calibration:** in one flagged /improve session, a clarifying question about cost mechanics triggered three full turns of database analysis across hundreds of sessions, adding substantial context cost with no actionable output.

### 7. Present findings and get approval

Open the findings message with a plain statement of what was found and what actions are proposed — keep interpretive framing in the body (an interpretive lead has cost a clarification turn at the gate before).

Present ALL findings to the user BEFORE making any changes. For each item, show:
- The lens that produced it (`config`, `retrospective`, `awareness`, `wide-view`, `skill-audit`)
- The evidence (specific issue numbers, dates, costs)
- The exact proposed change (file path + content diff, or action description)

Do NOT apply anything yet. Ask the user which items they approve. Wait for explicit validation.

If a proposed change involves creating a new skill, invoke `/skill-creator` to build it properly.

## Before you ship — anti-goals

Do NOT apply changes if ANY is true:
- [ ] The change was not explicitly named by the user in the findings-approval step.
- [ ] The finding has no cited session evidence.
- [ ] You are still in the read-only phase (before Step 7).

### 8. Apply and clean up

Only after user validation:
- Apply the approved file changes
- **If an approved change is meant to move a registered watch-item's metric, record it as an intervention** so the loop can later prove (or disprove) it worked instead of assuming it did. Add an `intervention: { date, baseline, expected_direction }` to that item in `$(logbook path watch)` (the current metric value is the baseline; `date` = today). `watch-report.sh --report` then renders the honest before/after around that date on the next run. This is the antidote to taking credit a model release actually earned (real intervention history: three prompt tweaks moved a metric not at all, a model bump did — the recorded baseline is what made that visible).
- **If any change touched the tool repo's `scripts/`, run its test suite BEFORE committing** — a broken script silently kills the session-tracking pipeline (seen in the wild: an applied edit added unescaped quotes to a worker prompt string, crashing every session-end for 3 days):
  ```bash
  TOOL_DIR="$(logbook env | grep '^TOOL_DIR=' | cut -d= -f2)"
  for t in "$TOOL_DIR"/scripts/tests/*.sh; do bash "$t" || echo "FAILED: $t"; done
  ```
  `test-syntax.sh` (`bash -n` over every script) is the cheap guard that catches the whole syntax-error class. Do not commit a script change while any test fails.
- Commit improvements to `~/.claude` repo if applicable
- Write today's date to state file:
  ```bash
  echo "$(date +%Y-%m-%d)" > $(logbook path state)/last-improve-date
  ```

## Guidelines

- Link every suggestion to observed data — no generic best practices
- Propose 2-4 high-impact items total, not a laundry list
- **Synthesize, don't list**: cluster related signals into single patterns
- Prefer editing existing files over creating new ones
- Check that proposed CLAUDE.md changes don't conflict with existing instructions
- If no meaningful patterns emerge, say so — don't force suggestions
- For new skills, always use `/skill-creator` (the native skill creation workflow)
- Articles: work with title + description metadata only — do NOT read/summarize article content
- **If a CLAUDE.md rule was already added for a recurring issue and the problem persists, propose a structural fix (hook, skill guard, prompt-level gate) instead of another rule**
