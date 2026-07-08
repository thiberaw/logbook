# logbook — Agent Instructions

See [CLAUDE.md](CLAUDE.md) for the project rules (two-roots discipline, test
suite, privacy gates). Highlights for any coding agent:

- All runtime writes go to the configured `DATA_DIR` (via `scripts/config.sh`
  variables) — the tool tree is read-only at runtime.
- After touching `scripts/`: `for t in scripts/tests/*.sh; do bash "$t"; done`
- Examples and test fixtures use placeholder names only.
