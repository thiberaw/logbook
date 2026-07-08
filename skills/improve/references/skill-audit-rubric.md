# Skill Audit Rubric

Score each skill 1-10 on 7 categories. Generate a finding when any category falls below its minimum threshold.

## 1. Trigger Precision (min: 6)

Does the description fire when needed and stay silent when not?

| Band | Score | Criteria |
|------|-------|----------|
| Poor | 1-3 | Vague description ("Helps with X"), missing trigger contexts, no action verbs |
| Fair | 4-5 | States what it does but not when to use it, or triggers too broadly |
| Good | 6-7 | Includes what + when, uses specific trigger phrases, third-person voice |
| Excellent | 8-10 | Covers synonyms/alternate phrasings, tested against similar skills for disambiguation |

Checklist:
- [ ] Description under 1024 characters
- [ ] Written in third person (no "I" or "you")
- [ ] States both what it does AND when to trigger
- [ ] Includes key terms a user would say (synonyms, alternate phrasings)
- [ ] Does not overlap ambiguously with other skills' descriptions
- [ ] Name follows clear noun-phrase or verb-noun convention

## 2. Instruction Clarity (min: 6)

Can Claude follow the skill without ambiguity?

| Band | Score | Criteria |
|------|-------|----------|
| Poor | 1-3 | Vague prose ("handle appropriately"), no clear steps, mixed concerns |
| Fair | 4-5 | Steps exist but some are ambiguous, freedom level mismatched to task fragility |
| Good | 6-7 | Clear sequential steps, appropriate freedom level, conditional branches marked |
| Excellent | 8-10 | Each step has explicit success criteria, decision points use conditional patterns, no ambiguous verbs |

Checklist:
- [ ] Steps are numbered or clearly sequenced
- [ ] No vague verbs ("handle", "process", "deal with") without qualification
- [ ] Freedom level matches task fragility (rigid for critical paths, flexible for creative work)
- [ ] Conditional branches are explicit ("if X -> do Y, else -> do Z")
- [ ] Input format and expected output format documented
- [ ] Success criteria defined (what does "done" look like?)

## 3. Context Efficiency (min: 5)

Does the skill justify its context window footprint?

| Band | Score | Criteria |
|------|-------|----------|
| Poor | 1-3 | Explains things Claude already knows, over 500 lines, walls of text |
| Fair | 4-5 | Some redundancy, bundled files exist but SKILL.md still too verbose |
| Good | 6-7 | SKILL.md under 500 lines, reference files used for detail, no redundant content |
| Excellent | 8-10 | Minimal SKILL.md with progressive disclosure, references organized by domain, grep-friendly structure |

Checklist:
- [ ] SKILL.md body under 500 lines
- [ ] No explaining standard concepts (what git does, what JSON is)
- [ ] Reference files used for detailed schemas/templates/examples
- [ ] References are one level deep (no chains of references)
- [ ] Code examples are minimal (show pattern, not full implementation)

## 4. Workflow Design (min: 5)

Are multi-step processes robust and well-structured?

| Band | Score | Criteria |
|------|-------|----------|
| Poor | 1-3 | No clear workflow, steps unordered, no feedback loops |
| Fair | 4-5 | Steps exist but no validation loops, no checklist pattern |
| Good | 6-7 | Clear workflow with validation steps and feedback loops |
| Excellent | 8-10 | Checklist pattern for tracking, validate-fix-repeat loops, graceful degradation for missing inputs |

Checklist:
- [ ] Multi-step tasks use numbered workflows
- [ ] Feedback loops present (run -> validate -> fix -> repeat)
- [ ] Graceful degradation defined for optional inputs/tools
- [ ] No implicit ordering dependencies (each step states its prerequisites)

## 5. Quality Assurance (min: 4)

Does the skill verify its own output?

| Band | Score | Criteria |
|------|-------|----------|
| Poor | 1-3 | No validation, output is fire-and-forget |
| Fair | 4-5 | Manual review suggested but no automated checks |
| Good | 6-7 | Explicit review steps, output format verified |
| Excellent | 8-10 | Automated validation, output presented for approval before applying |

Checklist:
- [ ] Output validated before being presented/applied
- [ ] User approval gate before destructive/irreversible actions
- [ ] Template pattern used for structured output where applicable

## 6. Error Handling (min: 4)

Is the skill resilient when things go wrong?

| Band | Score | Criteria |
|------|-------|----------|
| Poor | 1-3 | No error guidance, scripts fail silently, no fallbacks |
| Fair | 4-5 | Some error cases acknowledged but no recovery paths |
| Good | 6-7 | Common failure modes documented with fallback actions |
| Excellent | 8-10 | Explicit fallback chains, scripts handle exceptions, degradation rules documented |

Checklist:
- [ ] Common failure modes identified (missing files, MCP unavailable, empty results)
- [ ] Fallback behavior defined for each external dependency
- [ ] No silent failures (all errors produce actionable output)

## 7. Integration (min: 4)

Does the skill fit the broader ecosystem?

| Band | Score | Criteria |
|------|-------|----------|
| Poor | 1-3 | Duplicates existing functionality, conflicts with CLAUDE.md |
| Fair | 4-5 | Doesn't conflict but doesn't leverage ecosystem either |
| Good | 6-7 | Uses appropriate tools (gh, sqlite3, MCP), references related skills |
| Excellent | 8-10 | Delegates to specialized skills where appropriate, consistent terminology with CLAUDE.md |

Checklist:
- [ ] Does not duplicate functionality of another skill
- [ ] Uses available tools/MCP servers rather than reimplementing
- [ ] Delegates to specialized skills where appropriate
- [ ] File paths and tool references are correct and current

## 8. Failure-Mode Coverage (min: 6, action/mutation skills only)

Applies ONLY to action/mutation skills — those that ship code, open/edit PRs or branches, post comments, close/update issues, or change config/state (see `~/.claude/skills/_lib/inversion.md`). Read-only/reporting skills are exempt and score N/A.

| Band | Score | Criteria |
|------|-------|----------|
| Poor | 1-3 | Neither `## Failure modes` nor `## Before you ship — anti-goals` present |
| Fair | 4-5 | One of the two sections present |
| Good | 6-7 | Both present, each ≤5 items |
| Excellent | 8-10 | Both present, ≤5 items each, every failure bullet has a guard, seeded from real incidents |

Checklist:
- [ ] `## Failure modes` present (or an equivalent operational failure-modes section)
- [ ] `## Before you ship — anti-goals` present at the final state-changing gate
- [ ] Each section has ≤5 items
- [ ] Every `Failure modes` bullet names a guard
- [ ] Generate a finding for any action/mutation skill scoring below 6
