# Querying the sessions database

The database lives in the data dir (`logbook path db`). Use `sqlite3` directly
from any terminal.

> **Tip:** `-column -header` for readable tables, `-json` for piping to `jq`.

## Browse sessions

```bash
# All sessions (readable table)
sqlite3 -column -header "$(logbook path db)" \
  "SELECT date, project, name, duration, cost, status FROM sessions ORDER BY date DESC"

# Today's sessions
sqlite3 -column -header "$(logbook path db)" \
  "SELECT project, name, duration, cost, status FROM sessions WHERE date = '$(date +%Y-%m-%d)'"

# Last 7 days
sqlite3 -column -header "$(logbook path db)" \
  "SELECT date, project, duration, cost, description FROM sessions WHERE date >= date('now', '-7 days') ORDER BY date"

# JSON output (for piping to jq)
sqlite3 -json "$(logbook path db)" \
  "SELECT * FROM sessions WHERE date = '$(date +%Y-%m-%d)'"
```

## Look up a specific session

```bash
# By session ID
sqlite3 -column -header "$(logbook path db)" \
  "SELECT * FROM sessions WHERE session_id = '<uuid>'"

# By project
sqlite3 -column -header "$(logbook path db)" \
  "SELECT name, duration, cost, description FROM sessions WHERE project = 'my-app'"

# Flagged sessions only
sqlite3 -column -header "$(logbook path db)" \
  "SELECT date, project, issue, suggestion FROM sessions WHERE flagged = 1"
```

## Aggregates

```bash
# Cost by project
sqlite3 -column -header "$(logbook path db)" \
  "SELECT project, COUNT(*) as sessions, SUM(duration) as minutes, ROUND(SUM(cost),2) as total_cost
   FROM sessions GROUP BY project ORDER BY total_cost DESC"

# Cost by day
sqlite3 -column -header "$(logbook path db)" \
  "SELECT date, COUNT(*) as sessions, SUM(duration) as minutes, ROUND(SUM(cost),2) as cost
   FROM sessions GROUP BY date ORDER BY date"
```

## Schema

```bash
sqlite3 "$(logbook path db)" ".schema sessions"
```

Column meanings are documented in [architecture.md §9](architecture.md).
