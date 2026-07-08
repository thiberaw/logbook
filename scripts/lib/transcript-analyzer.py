#!/usr/bin/env python3
"""Analyze Claude Code transcript JSONL files for session heuristics and condensed output.

Usage:
  python3 transcript-analyzer.py <path>                # Metrics mode (JSON output)
  python3 transcript-analyzer.py --condensed <path>    # Condensed transcript (text output)
  python3 transcript-analyzer.py --first-prompt <path> # First user prompt (plain text, 120 chars max)
"""

import json
import re
import sys
from collections import defaultdict
from typing import Optional


# ---------- Regex patterns for test detection ----------

TEST_CMD_RE = re.compile(
    r"jest|vitest|pytest|pnpm (?:run )?test|npm (?:run )?test|yarn test"
    r"|npx jest|npx vitest|bun test|go test|cargo test|pnpm (?:run )?type-check"
)

TEST_FAIL_RE = re.compile(
    r"FAIL|FAILED|ERROR|failures? [1-9]|error TS\d+|AssertionError|test.*failed|exit code [1-9]"
)

TEST_PASS_RE = re.compile(
    r"PASS|passed|Tests: \d+ passed|All \d+ tests? passed|0 failures|0 errors|exit code 0"
)



# ---------- Parsing helpers ----------


def parse_jsonl(path: str):
    """Yield parsed JSON objects from a JSONL file, skipping invalid lines."""
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def get_content_blocks(entry: dict) -> list:
    """Extract the content block list from an assistant or user entry."""
    message = entry.get("message", {})
    if not isinstance(message, dict):
        return []
    content = message.get("content", [])
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    if isinstance(content, list):
        return content
    return []


def extract_text_from_content(content) -> str:
    """Extract plain text from a message content field (string or block array)."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, str):
                parts.append(block)
            elif isinstance(block, dict):
                if block.get("type") == "text":
                    parts.append(block.get("text", ""))
        return " ".join(parts)
    return ""


def is_substantive_text(text: str) -> bool:
    """Return True if the text is non-empty and not just whitespace/newlines."""
    stripped = text.strip()
    return len(stripped) > 0


# ---------- Metrics extraction ----------


# Per-model pricing, USD per million tokens. Source: the official pricing page
# (platform.claude.com/docs/en/about-claude/pricing), fetched 2026-06-12 — the
# previous hardcoded $15/$75 were Opus 4.1 rates, overstating Opus 4.5+ session
# costs ~3x. Cache writes bill at 1.25x input (5-minute TTL, the Claude Code
# default); cache reads at 0.1x input. Matched by substring on the model id so
# date-suffixed ids resolve; order matters (opus-4-1 before the generic opus).
# Unknown models price at the highest current tier so estimates err HIGH, never
# silently low. All downstream consumers treat cost as an ESTIMATE.
MODEL_PRICING = [
    # (model-id substring, input $/M, output $/M)
    ("fable", 10.0, 50.0),
    ("mythos", 10.0, 50.0),
    ("opus-4-1", 15.0, 75.0),   # deprecated models keep their old rates
    ("opus-4-0", 15.0, 75.0),
    ("opus", 5.0, 25.0),        # Opus 4.5 through 4.8
    ("sonnet", 3.0, 15.0),
    ("haiku-3-5", 0.8, 4.0),
    ("haiku", 1.0, 5.0),
]
FALLBACK_PRICING = (10.0, 50.0)


def price_for_model(model: str) -> tuple:
    """Return (input $/M, output $/M) for a model id, by substring match."""
    m = model.lower()
    for needle, inp, out in MODEL_PRICING:
        if needle in m:
            return (inp, out)
    return FALLBACK_PRICING


def extract_metrics(path: str) -> dict:
    """Parse a transcript and return session metrics as a dict."""
    total_turns = 0
    tool_calls: dict[str, int] = defaultdict(int)
    tool_errors = 0
    files_modified: set[str] = set()
    tests_run = False
    test_outputs: list[str] = []

    # Token tallies keyed by the model id that produced them, so each model's
    # tokens are priced at that model's rates (sessions mix models: main loop
    # on one tier, subagents/background tasks on others).
    tokens_by_model: dict[str, dict[str, int]] = defaultdict(
        lambda: {"input": 0, "output": 0, "cache_read": 0, "cache_creation": 0}
    )
    human_prompts = 0
    git_branch: Optional[str] = None
    first_timestamp: Optional[str] = None
    last_timestamp: Optional[str] = None

    # Track which assistant messages we've already counted (by message id)
    # because assistant messages can be streamed across multiple JSONL entries.
    counted_assistant_msgs: set[str] = set()
    # Track unique user message UUIDs to count human prompts
    seen_user_uuids: set[str] = set()
    # Track seen (model, usage) to deduplicate streamed assistant entries
    seen_usage_keys: set[str] = set()

    for entry in parse_jsonl(path):
        entry_type = entry.get("type", "")
        timestamp = entry.get("timestamp")

        # Track time span
        if timestamp:
            if first_timestamp is None:
                first_timestamp = timestamp
            last_timestamp = timestamp

        # Track git branch (take the first non-empty one)
        if git_branch is None:
            branch = entry.get("gitBranch")
            if branch:
                git_branch = branch

        if entry_type == "assistant":
            msg = entry.get("message", {})
            if not isinstance(msg, dict):
                continue

            # Token usage (deduplicate by request ID or message ID)
            usage = msg.get("usage")
            msg_id = msg.get("id", "")
            request_id = entry.get("requestId", "")
            usage_key = request_id or msg_id

            if usage and isinstance(usage, dict) and usage_key:
                if usage_key not in seen_usage_keys:
                    seen_usage_keys.add(usage_key)
                    tally = tokens_by_model[msg.get("model", "") or ""]
                    tally["input"] += usage.get("input_tokens", 0)
                    tally["output"] += usage.get("output_tokens", 0)
                    tally["cache_read"] += usage.get("cache_read_input_tokens", 0)
                    tally["cache_creation"] += usage.get("cache_creation_input_tokens", 0)

            blocks = get_content_blocks(entry)
            for block in blocks:
                if not isinstance(block, dict):
                    continue
                btype = block.get("type", "")

                if btype == "text":
                    text = block.get("text", "")
                    if is_substantive_text(text):
                        key = (msg_id, text.strip())
                        if key not in counted_assistant_msgs:
                            counted_assistant_msgs.add(key)
                            total_turns += 1

                elif btype == "tool_use":
                    tool_name = block.get("name", "unknown")
                    tool_calls[tool_name] += 1
                    tool_input = block.get("input", {})

                    # Track files modified by Edit/Write/MultiEdit
                    if tool_name in ("Edit", "Write", "MultiEdit"):
                        fp = tool_input.get("file_path", "")
                        if fp:
                            files_modified.add(fp)

                    # Detect test runs from Bash commands
                    if tool_name == "Bash":
                        cmd = tool_input.get("command", "")
                        if TEST_CMD_RE.search(cmd):
                            tests_run = True

        elif entry_type == "user":
            # Count distinct human prompts
            user_type = entry.get("userType", "")
            uuid = entry.get("uuid", "")
            if user_type == "external" and uuid and uuid not in seen_user_uuids:
                seen_user_uuids.add(uuid)
                msg = entry.get("message", {})
                content = msg.get("content", "") if isinstance(msg, dict) else ""
                has_text = False
                if isinstance(content, str) and content.strip():
                    has_text = True
                elif isinstance(content, list):
                    for b in content:
                        if isinstance(b, dict) and b.get("type") == "text" and b.get("text", "").strip():
                            has_text = True
                            break
                if has_text:
                    human_prompts += 1

            blocks = get_content_blocks(entry)
            for block in blocks:
                if not isinstance(block, dict):
                    continue
                btype = block.get("type", "")

                if btype == "tool_result":
                    if block.get("is_error", False):
                        tool_errors += 1

                    # Collect test output for pass/fail analysis
                    result_content = block.get("content", "")
                    if isinstance(result_content, str) and result_content:
                        test_outputs.append(result_content)

    # Determine test pass/fail from collected outputs
    tests_passed: Optional[bool] = None
    if tests_run:
        has_fail = False
        has_pass = False
        for output in test_outputs:
            if TEST_FAIL_RE.search(output):
                has_fail = True
            if TEST_PASS_RE.search(output):
                has_pass = True
        if has_fail:
            tests_passed = False
        elif has_pass:
            tests_passed = True

    # Estimate cost in USD per model, at each model's own rates (see
    # MODEL_PRICING above). This is an ESTIMATE from token counts, not a billed
    # amount — downstream consumers label it as such.
    cost_usd = None
    if any(t["input"] > 0 or t["output"] > 0 for t in tokens_by_model.values()):
        cost = 0.0
        for model, t in tokens_by_model.items():
            in_rate, out_rate = price_for_model(model)
            cost += (t["input"] + 1.25 * t["cache_creation"]) * in_rate / 1_000_000
            cost += t["cache_read"] * 0.1 * in_rate / 1_000_000
            cost += t["output"] * out_rate / 1_000_000
        cost_usd = round(cost, 3)

    return {
        "total_turns": total_turns,
        "human_prompts": human_prompts,
        "total_tool_calls": sum(tool_calls.values()),
        "tool_errors": tool_errors,
        "files_modified_count": len(files_modified),
        "tests_passed": tests_passed,
        "git_branch": git_branch,
        "cost_usd": cost_usd,
        "first_timestamp": first_timestamp,
        "last_timestamp": last_timestamp,
    }


# ---------- First prompt extraction ----------


def parse_slash_command(text: str) -> Optional[str]:
    """If a user message is a slash-command invocation, return it as readable
    '/command args' text; otherwise return None.

    Claude Code wraps slash commands in XML-ish tags, e.g.:
      <command-message>review-pr</command-message>
      <command-name>/review-pr</command-name>
      <command-args>https://github.com/.../pull/8092</command-args>
    These start with '<', so they were dropped as meta noise. The flag-analysis
    LLM then saw the *next* plain-text turn (e.g. "post it") as the opening
    prompt and wrongly judged the session as launched from minimal/cryptic input.
    Surfacing the command + args keeps the user's real, fully-scoped intent in
    the trace.
    """
    name = re.search(r"<command-name>\s*(/[^<]+?)\s*</command-name>", text)
    if not name:
        return None
    cmd = name.group(1).strip()
    args = re.search(r"<command-args>\s*([^<]*?)\s*</command-args>", text)
    if args and args.group(1).strip():
        cmd = f"{cmd} {args.group(1).strip()}"
    return cmd


def extract_first_prompt(path: str) -> str:
    """Return the first substantive user message, truncated to 120 chars."""
    for entry in parse_jsonl(path):
        entry_type = entry.get("type", "")

        if entry_type == "user":
            message = entry.get("message", {})
            if isinstance(message, dict):
                content = message.get("content", "")
            else:
                continue
        elif entry.get("role") in ("human", "user"):
            content = entry.get("content", "")
        else:
            continue

        text = extract_text_from_content(content).strip()

        # Surface slash-command invocations (tag-wrapped) as their real intent
        slash = parse_slash_command(text)
        if slash:
            text = slash

        # Skip very short or system-like messages
        if len(text) < 5:
            continue
        if text.startswith("<"):
            continue
        if text.startswith("You are a"):
            continue

        # Truncate to 120 chars
        if len(text) > 120:
            return text[:117] + "..."
        return text

    return ""


# ---------- Condensed transcript ----------


def extract_condensed(path: str) -> str:
    """Parse a transcript and return a chronological condensed trace.

    Output format: one line per event, prefixed with [T{turn}]:
      [T1] Grep: "auth" in src/
      [T1] ERROR: file not found
      [T2] → Switching approach to...
    """
    first_prompt: Optional[str] = None
    events: list[str] = []
    turn = 0

    # Track deduplicated assistant text messages (streamed duplicates)
    seen_assistant_texts: set[tuple[str, str]] = set()

    for entry in parse_jsonl(path):
        entry_type = entry.get("type", "")

        if entry_type == "user":
            blocks = get_content_blocks(entry)
            message = entry.get("message", {})
            content = message.get("content", "") if isinstance(message, dict) else ""

            # Extract user prompt text (skip tool_result blocks)
            prompt_text = ""
            if isinstance(content, str):
                prompt_text = content.strip()
            elif isinstance(content, list):
                text_parts = []
                for block in content:
                    if isinstance(block, str):
                        text_parts.append(block)
                    elif isinstance(block, dict) and block.get("type") == "text":
                        text_parts.append(block.get("text", ""))
                    # Skip tool_result blocks for prompt text
                prompt_text = " ".join(text_parts).strip()

            # Surface slash-command invocations (tag-wrapped) as their real
            # intent so the opening "/review-pr <url>" is not dropped in favor
            # of a later plain-text turn like "post it".
            slash = parse_slash_command(prompt_text)
            if slash:
                prompt_text = slash

            # Skip system/meta messages and skill-invocation boilerplate
            is_real_prompt = (
                len(prompt_text) >= 5
                and not prompt_text.startswith("<")
                and not prompt_text.startswith("Base directory for this skill:")
            )

            if first_prompt is None:
                if is_real_prompt:
                    first_prompt = prompt_text[:2000]
            elif is_real_prompt:
                # Emit subsequent user prompts as trace events so the
                # flag-analysis LLM can see mid-session authorizations
                # (e.g. "Post it as a comment") rather than judging the
                # whole session against the opening prompt alone.
                events.append(f"[T{turn}] USER: {prompt_text[:300]}")

            # Collect tool results (chronologically). Errors get the loud ERROR
            # marker; successful results get a terse "⤷" outcome line so the
            # analysis LLM sees consequences, not just actions (2026-06-17).
            for block in blocks:
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    res_content = block.get("content", "")
                    if block.get("is_error", False):
                        err_text = extract_text_from_content(res_content)
                        if err_text:
                            events.append(f"[T{turn}] ERROR: {err_text[:300]}")
                    else:
                        summary = _summarize_tool_result(res_content, False)
                        if summary:
                            events.append(f"[T{turn}] ⤷ {summary}")

        elif entry_type == "assistant":
            blocks = get_content_blocks(entry)
            msg = entry.get("message", {})
            msg_id = msg.get("id", "") if isinstance(msg, dict) else ""

            for block in blocks:
                if not isinstance(block, dict):
                    continue
                btype = block.get("type", "")

                if btype == "text":
                    text = block.get("text", "")
                    if is_substantive_text(text):
                        key = (msg_id, text.strip())
                        if key not in seen_assistant_texts:
                            seen_assistant_texts.add(key)
                            turn += 1
                            events.append(f"[T{turn}] \u2192 {text.strip()[:300]}")

                elif btype == "tool_use":
                    tool_name = block.get("name", "unknown")
                    tool_input = block.get("input", {})
                    summary = _summarize_tool_call(tool_name, tool_input)
                    events.append(f"[T{turn}] {summary}")

    # Build output
    lines = []
    lines.append("=== FIRST USER PROMPT ===")
    lines.append(first_prompt or "(none)")
    lines.append("")
    lines.append(f"=== CHRONOLOGICAL TRACE ({len(events)} events) ===")
    for e in events:
        lines.append(e)

    return "\n".join(lines)


def _summarize_tool_call(name: str, inp: dict) -> str:
    """Create a one-line summary of a tool call."""
    if name == "Bash":
        cmd = inp.get("command", "")
        desc = inp.get("description", "")
        key = desc if desc else cmd
        return f"Bash: {key[:120]}"
    elif name == "Read":
        return f"Read: {inp.get('file_path', '?')}"
    elif name == "Edit":
        return f"Edit: {inp.get('file_path', '?')}"
    elif name == "Write":
        return f"Write: {inp.get('file_path', '?')}"
    elif name == "MultiEdit":
        return f"MultiEdit: {inp.get('file_path', '?')}"
    elif name == "Glob":
        return f"Glob: {inp.get('pattern', '?')} in {inp.get('path', '.')}"
    elif name == "Grep":
        return f"Grep: {inp.get('pattern', '?')}"
    elif name == "Task":
        return f"Task: {inp.get('description', '?')[:80]}"
    else:
        # Generic: show first key-value
        keys = list(inp.keys())
        if keys:
            first_key = keys[0]
            val = str(inp[first_key])[:80]
            return f"{name}: {first_key}={val}"
        return f"{name}"


def _summarize_tool_result(content, is_error: bool) -> str:
    """One-line summary of a tool RESULT (2026-06-17 evidence-grounding review).

    The condensed trace used to drop every result except errors, so the analysis
    LLM saw actions without consequences — it knew Claude read a file but not
    whether the read returned the answer or garbage. This surfaces a terse
    outcome (size + a content peek) so spirals ("read 12 files, none helped")
    and dead-ends become visible.
    """
    text = extract_text_from_content(content)
    if not text:
        return "(empty)" if not is_error else ""
    # Collapse whitespace and peek at the head; report size so a big-read /
    # huge-log-download is legible as a cost driver.
    flat = " ".join(text.split())
    nlines = text.count("\n") + 1
    peek = flat[:100]
    return f"{len(text)}b/{nlines}L: {peek}"


# ---------- Main ----------


def main():
    args = sys.argv[1:]

    if not args or (len(args) == 1 and args[0] in ("-h", "--help")):
        print(__doc__.strip())
        sys.exit(0)

    condensed = False
    first_prompt = False
    path = None

    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--condensed":
            condensed = True
        elif arg == "--first-prompt":
            first_prompt = True
        elif not arg.startswith("-"):
            path = arg
        i += 1

    if not path:
        print("Error: no transcript path provided", file=sys.stderr)
        sys.exit(1)

    if first_prompt:
        print(extract_first_prompt(path))
    elif condensed:
        print(extract_condensed(path))
    else:
        metrics = extract_metrics(path)
        print(json.dumps(metrics, indent=2))


if __name__ == "__main__":
    main()
