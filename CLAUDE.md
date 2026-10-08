# logbook — Project Rules

Operating rules for working on the logbook tool.

## What this repo is

The engine only: session-tracking hooks, the morning-review TUI, the analysis
worker, the reporters, and the `improve`/`daily-status` skills. All user data
lives in a separate configured `DATA_DIR` — never commit user output, real
project names, or transcripts into this repo.

## Two roots — keep them straight

- `TOOL_DIR` (this repo) is read-only at runtime. Nothing here may be written
  by a running script except the gitignored skill-state files.
- `DATA_DIR` (configured) receives every write: DB, daily/reviewed output,
  docs, weekly summaries. New paths go through `scripts/config.sh` variables,
  never hardcoded.

## Quality gates

- Run the test suite after any change to `scripts/`:
  `for t in scripts/tests/*.sh; do bash "$t"; done`
  Tests must stay hermetic (mktemp fixtures, env-var path overrides) and must
  pass on a fresh clone with no data dir and no eval corpus.
- `bash -n` every touched script (test-syntax.sh covers this in the suite).
- Reporters emit **evidence, never verdicts** — no CLOSE/REOPEN/score strings.

## Privacy

- Example data uses placeholder names (`my-app`, `acme-app`, `/home/you/…`).
- Prose states lessons, not incidents — skills, docs, AND code comments: no
  dates, dollar amounts, ticket/PR/commit IDs, or session details from real
  usage ("an interpretive lead has cost a turn before", not "the 05-12 $19.80
  run"). Synthetic test-fixture values and format examples are fine. Applies
  to every /improve edit here.
- Before any public push: grep the repo for every term in the private PII
  denylist (`$(logbook path state)/pii-denylist.txt`, gitignored) — it must
  return nothing. Sole content exemption: the repo's own public clone URL
  in the README.
  `grep -riFf <(grep -vE '^(#|$)' "$(logbook path state)/pii-denylist.txt" | cut -d'|' -f1) . --exclude-dir=.git \ | grep -vF 'github.com/thiberaw/logbook'`
- The eval corpus, user docs, and anything derived from real sessions belong
  in the data dir, not here.
