# /improve — Analysis Lenses

Five lenses applied in step 6 of the workflow. Each produces 0–1 items. Target 2–4 total per run.

## Contents
- [Graceful degradation](#graceful-degradation) — when to skip a lens
- [Config lens](#config-lens) — recurring suggestions, cost outliers, hooks
- [Retrospective lens](#retrospective-lens) — themes across days
- [Awareness lens](#awareness-lens) — articles vs. pain points
- [Wide-view lens](#wide-view-lens) — broader workflow patterns
- [Skill-audit lens](#skill-audit-lens) — quality of skills in `~/.claude/skills/`

## Graceful degradation
- < 5 sessions in window → skip awareness and wide-view lenses (not enough signal)
- No `suggested_articles` in window → skip awareness lens
- No recurring patterns (< 3 occurrences of same theme) → skip retrospective lens
- context7 MCP unavailable → use local `anthropic-best-practices.md` as skill-audit rubric baseline
- < 3 skills in `~/.claude/skills/` → skip skill-audit lens
- If only 1 lens produces a finding → that's fine, output 1 item

## Config lens

Recurring suggestions, error rates, skill gaps, CLAUDE.md gaps, hooks.

| Pattern | Signal |
|---------|--------|
| **Recurring suggestions** | Same suggestion across 2+ flagged issues → high-priority |
| **Waste** | Flagged issues — themes in the Issue/Friction sections |
| **Skill gaps** | Tasks that could benefit from a skill but `skill:` label absent |
| **Cost outliers** | Sessions with cost > $15 or cost-per-turn > $1.00 → investigate root cause |
| **Duration outliers** | Sessions >60min that might need better prompts or skills |
| **High error rates** | Tool errors from metrics table > 10% of tool calls |
| **Missing hooks** | Repetitive manual steps that could be automated |
| **CLAUDE.md gaps** | Instructions missing given observed patterns |
| **Permission friction** | Recurring permission blocks noted in Friction sections |

Output: **File change** (CLAUDE.md, hooks, settings, skill edits).

## Retrospective lens

Cluster suggestions by theme across days. Input sources (in priority order):
1. **Improvement Signals from reviewed files** — covers ALL sessions, not just flagged. Richest source for pattern detection.
2. **Flagged session `issue`/`suggestion` from database** — concentrated problem areas.
3. **User `reflection.note`** — user-identified gaps and priorities.

Surface themes with 3+ occurrences OR themes the user flagged in `reflection.note`. **Synthesize** the root pattern — don't list individual suggestions.

Example: "5 improvement signals across 3 days recommend 'document auth patterns'" → 1 pattern: "Auth-related investigations repeatedly rediscover the same code paths, lacking shared context docs."

Additional signals:
- Multiple flagged issues on the same project → concentrated pain point
- Non-flagged improvement signals that echo flagged suggestions → converging evidence across severity levels
- `reflection.note` themes → user-identified gaps

Output: **File change** or **Action** (process rule, workflow change).

## Awareness lens

Compare article titles/descriptions vs actual session issues from the same period:
- If articles consistently miss pain points → propose keyword/source changes to `fetch-articles.sh`. Read the script first.
- If one article genuinely matches a real gap → surface it as "Read: <title>" with a 1-sentence explanation of why it's relevant.

Output: **Source tuning** (fetch-articles.sh changes) or **recommendation** (read this article).

## Wide-view lens

Look for broader workflow patterns beyond Claude Code config:
- Multi-session workflows that should be combined
- Tools/MCP servers available but unused for observed tasks
- Task types without skills
- Process patterns (always doing X then Y → automate the sequence)

Must cite specific session evidence (issue numbers). Not "consider using X" but concrete proposals.

Output: **Action** (workflow/tool/process change, new automation, skill combination).

## Skill-audit lens

Audit skills in `~/.claude/skills/` against a quality rubric grounded in current Anthropic documentation.

**Context budget (added 2026-05-11 after 2 weeks of recurring self-flags on context bloat):**
- Audit at most **3 skills per run** (rotated). Loading 15+ SKILL.md files at once causes the bloat flagged on 2026-04-30 and 2026-05-07.
- Use a **local cache** for Anthropic skill guidance, refreshed at most weekly. Skip context7 MCP unless the cache is stale or missing.

**Data gathering:**
1. **Anthropic skill guidance** — read `~/.claude/skills/improve/references/anthropic-skill-guidance.md`:
   - If the file exists and was modified within the last 7 days (`find -mtime -7`), use it as-is.
   - If missing or stale: refresh via context7 MCP (`resolve-library-id("anthropic claude code skills")` → `query-docs(id, "skill authoring best practices quality criteria")`) and write the result to that path before continuing. If MCP fails, fall back to `~/.claude/plugins/cache/claude-plugins-official/superpowers/*/skills/writing-skills/anthropic-best-practices.md`.
2. **Skill rotation** — read `~/.claude/skills/improve/.audit-cursor` (one filename per line, e.g. `analyze-ticket`):
   - If the cursor file is empty, missing, or all skills have been audited (cursor == `__done__`), regenerate it from `ls ~/.claude/skills/` (sorted), reset to top.
   - Pick the next 3 skill names from the cursor. Read **only those** SKILL.md files (plus their bundled reference files if needed for the failing categories).
   - After scoring, append the audited 3 names back to a `__done__` section and write the updated cursor.

**Scoring:**
Read `references/skill-audit-rubric.md` for full criteria. Score each of the 3 audited skills 1-10 on 7 categories. Merge cached Anthropic guidance with the stable rubric — the rubric provides scoring structure, cached docs provide checklist content.

**Finding generation:**
- Only surface skills with at least one category below its minimum threshold
- Group findings by skill (one finding per skill, listing all failing categories)
- Prioritize by: number of failing categories, then severity of worst score
- Cap at 2 findings per run (worst offenders)
- This lens audits itself (the improve skill) — no exceptions

Output: **File change** (SKILL.md edit, description update, reference file restructure) or **Action** (split skill, add progressive disclosure, fix integration).
