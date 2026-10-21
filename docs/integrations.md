# Recording sessions from other tools

logbook tracks Claude Code CLI sessions through its `SessionStart`/`SessionEnd`
hooks, but the session store is not CLI-specific. Any tool — an editor plugin,
another agent, a script — can record a session by writing one row to the same
database the reporters read.

## The contract

The reporters (`logbook status`, the morning review, the weekly summary) read
sessions **only** from the SQLite database — never from `daily/*.json`. So
recording a session is a single `INSERT` into the `sessions` table. Find the
database with:

```sh
logbook path db
```

The table already exists after `install.sh`. **Insert into it; never create it**
yourself — that avoids drifting from the real schema (authoritative definition:
[`scripts/lib/sessions-db.sh`](../scripts/lib/sessions-db.sh)).

## Minimal example

```sh
sqlite3 "$(logbook path db)" "INSERT OR IGNORE INTO sessions
  (session_id, name, project, date, branch, duration, turns, first_prompt, status)
  VALUES ('11111111-2222-4333-8444-555555555555', '[my-app] my-tool: chat',
          'my-app', '2026-01-01', 'main', 8, 4, 'first user prompt…', 'done');"
```

Once the row has a `date`, it shows up in `logbook status`, the morning review,
and the weekly summary alongside your CLI sessions.

## Fields

| Column | Notes |
|---|---|
| `session_id` | `UNIQUE NOT NULL`. Use a UUID. `INSERT OR IGNORE` makes a re-run a no-op instead of an error. |
| `date` | `NOT NULL`, **local** `YYYY-MM-DD` — use the local date so day boundaries line up with the review (the CLI hook does the same). |
| `duration` | Minutes. |
| `turns` | Human turns. Set it `> 0`: daily-status warns about days where most `done` sessions have `turns = 0` (a sign the CLI pipeline failed), and you don't want external rows tripping that check. |
| `status` | `'done'` for a finished session. An `'in_progress'` row is swept to `done` after 2h by the next `SessionStart`. |
| `name` | Free text shown in reports. Encode the origin so external rows are recognisable, e.g. `[project] <tool>: <label>`. (CLI rows read `[project] <name> (<dur>m, $<cost>)`.) |
| `first_prompt` | Optional; the opening user message, handy in the review. |

Every other column (`cost`, `tool_calls`, `tool_errors`, `files_modified`, the
narrative fields, …) has a default and can be omitted. The CLI fills those from
the Claude Code transcript; a tool without a transcript simply leaves them empty,
which the reporters handle fine.

## Full parity, when a transcript exists

The minimal INSERT above records a session but leaves the metrics empty. If your
tool drives Claude through something that writes a **Claude Code-format
transcript** (a `.jsonl` with the usual `message`/`usage`/`tool_use` entries) —
for example an ACP agent run from an editor — hand that file to logbook instead
and get a row identical to a CLI session: cost, turns, tool calls, errors, files
modified, the narrative, and flagging.

```sh
logbook record-transcript /path/to/session.jsonl [--source <tag>]
```

- It reads the session id and working directory from the transcript, inserts the
  row (idempotent — re-running just refreshes the metrics), and runs the same
  analysis the CLI's `SessionEnd` hook runs.
- `--source <tag>` appends an origin label to the row name (e.g.
  `[my-app] … [my-tool]`) so external rows stay recognisable in the reports.
- It is tool-agnostic: it only reads the transcript you point it at. Where the
  transcript lives, and when to record it, is the integrating tool's concern.

## Example in the wild

A Neovim + CodeCompanion setup can record each chat on close by hooking the
plugin's `CodeCompanionChatClosed` (and a `VimLeavePre` flush as a backstop).
If the editor's agent leaves a transcript, the close hook calls
`logbook record-transcript <transcript> --source <tool>` for full parity;
otherwise it runs the minimal `INSERT` above — either way recording editor AI
sessions into the same database as the CLI, with no change to logbook itself.
