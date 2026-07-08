---
name: daily-status
description: Shows today's status — reads session data from local SQLite database and daily metadata from JSON, summarizes sessions/projects/PRs, regenerates the daily markdown report. Use when asked for today's status, a daily summary, or invoked as /daily-status.
---

# /daily-status — Daily Status Summary

You are a status reporter. Your job is to read today's activity data and produce a concise summary.

## Step 0 — hard guard

```bash
command -v logbook >/dev/null || { echo "logbook not on PATH — run the tool's install.sh"; exit 1; }
```

All paths below resolve through the `logbook` CLI; without it on PATH the queries would run against empty strings.

## Input

The user invokes `/daily-status` (no arguments needed).

## Step 1: Read today's session data from SQLite

Query the local sessions database:
```bash
sqlite3 -json "$(logbook path db)" \
  "SELECT name AS Name, project AS Project, date AS Date, duration AS Duration,
          cost AS Cost, branch AS Branch, skill AS Skill, description AS Description,
          turns AS Turns, tool_calls AS Tool_Calls, tool_errors AS Tool_Errors,
          files_modified AS Files_Modified, flagged AS Flagged, issue AS Issue,
          suggestion AS Suggestion
   FROM sessions WHERE date = '$(date +%Y-%m-%d)' ORDER BY created_at"
```

## Step 1b: Pipeline health check

After querying sessions, check for signs of session-end pipeline failure:
```bash
sqlite3 "$(logbook path db)" \
  "SELECT COUNT(*) FROM sessions WHERE date >= date('now', '-1 day') AND turns = 0 AND status = 'done'"
```

If more than half of recent done sessions have 0 turns, show a warning:
> **Pipeline health**: {N} of {total} recent sessions have empty metrics. Check the session-end log for errors.

Also check if the log exists and show the last error:
```bash
tail -5 "$(logbook path state)/session-end.log" 2>/dev/null
```

## Step 2: Read today's daily metadata

Read the daily JSON file for non-session data:
- Path: `$(logbook path daily)/${TODAY}.json`
- Contains: intention, reflection, git_activity, pull_requests, suggested_articles

If the file doesn't exist, check yesterday's date as fallback and note it.

## Step 3: Summarize activity

### Sessions (from SQLite)
- Total session count
- Breakdown by project
- Total duration and cost
- Flagged session count

### Work Output (from daily JSON)
- PRs opened or merged today
- Commits made
- Issues closed or progressed

### Projects Touched
- List each project with a one-line summary of what was done

## Step 4: Regenerate daily report

```bash
logbook status 2>/dev/null
```

If the command fails, skip silently.

## Output format

### Today: {date}

**Intention**: {from JSON file or "none set"}

**Sessions**: {count} across {n} projects
{project breakdown with durations and costs}

**Output**:
- PRs: {opened/merged/reviewed}
- Commits: {count}

---

**Important rules:**
- Do NOT make changes to any files other than regenerating the daily report
- If data is missing, say so clearly rather than guessing
- Keep the output concise — this is a quick status check
- Use the current date, not a hardcoded one
