# logbook

Record every Claude Code session into a local SQLite database, reflect on them
each morning, and feed what you learn back into your setup.

The tool is three surfaces over one data directory you configure:

- **Session tracking** — `SessionStart`/`SessionEnd` hooks insert a row per
  session (project, duration, cost, turns, tool calls/errors, files modified),
  then a background worker adds an LLM-written narrative, deterministic
  cross-checks, and a waste-detection flag.
- **Morning review** — an interactive `gum` TUI that walks each unreviewed
  day: sessions, PRs, improvement signals, your reflection note. Writes an
  immutable `reviewed/<date>.md` per day and commits it (if the data dir is a
  git repo).
- **Improvement loop** — the `/improve` Claude Code skill reads the database
  and the review output, checks open concerns against evidence, and proposes
  config/skill/hook changes; `watch-report` and `hook-report` compute the
  evidence half of that loop.

## Install

```bash
git clone https://github.com/thiberaw/logbook.git
cd logbook && ./install.sh
```

Clone it somewhere permanent — the installer symlinks into the clone, so if
you move the directory later, re-run `install.sh` to refresh the links.

`install.sh` verifies dependencies (required: `jq`, `sqlite3`, `python3`, `git`;
recommended: `gum` for the TUI, `gh` for PR scanning), symlinks the `logbook`
CLI onto your PATH plus the two skills into `~/.claude/skills/`, asks one
question (where to store your data), seeds the data directory, and prints the
hook block to paste into `~/.claude/settings.json`. Re-running it upgrades the
symlinks and touches nothing else.

## Quickstart

```bash
# after installing and pasting the hook block:
# 1. run any Claude Code session
sqlite3 "$(logbook path db)" 'SELECT count(*) FROM sessions'   # → 1

# 2. next morning
logbook morning-review

# 3. anytime
logbook status          # today's sessions and cost
logbook watch-report    # evidence for your open concerns
logbook hook-report     # are your guard hooks earning their keep?
```

## Configuration

Resolution order: `LOGBOOK_DATA_DIR` env var > `~/.config/logbook/config` >
`~/.local/share/logbook`. The config file is strict `KEY=value`, one per line
(no quotes, no inline comments). Recognised keys:

| Key | Meaning |
|---|---|
| `LOGBOOK_DATA_DIR` | where all output lives (may be a private git repo — then reviews auto-commit and push) |
| `LOGBOOK_PROJECTS_DIR` | directory holding *only* your git repos; enables PR scanning (unset = skipped) |
| `LOGBOOK_GIT_USER` | git author to track (default: `git config user.name`) |
| `LOGBOOK_FIXTURES_DIR` | private eval corpus location (default: `<data>/eval/fixtures`) |
| `LOGBOOK_ARTICLE_SOURCES` | article sources for review suggestions: `all` (default) or a comma-separated whitelist — `install.sh` offers a picker; ids listed in `lib/fetch-articles.sh` |

Example query against your own history (more in
[docs/querying.md](docs/querying.md)):

```bash
sqlite3 "$(logbook path db)" "SELECT date, name, cost FROM sessions WHERE project = 'my-project'"
```

## Data layout

Everything user-generated lives in the data dir, never in this repo:
`daily/*.json` (per-day metadata), `reviewed/*.md` (immutable review output),
`docs/` (open-concerns, watch-items), `<year>/<month>/` (weekly summaries),
`.state/` (gitignored runtime: the SQLite DB, logs, caches), and
`eval/fixtures/` (the private flag-analysis corpus — verbatim transcripts of
your real work; the tests skip cleanly when it is absent).

## Development

`scripts/README.md` maps how the scripts fit together; `docs/architecture.md`
tells the data-flow story. Tests are hermetic and self-contained:

```bash
for t in scripts/tests/*.sh; do bash "$t"; done
```
