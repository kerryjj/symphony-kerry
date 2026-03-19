---
title: "Mix task for Codex trace JSONL inspection"
problem_type: developer-tooling
component: Symphony Elixir — Codex trace/debug tooling
symptom: No tool to inspect Codex trace JSONL files at log/traces/{issue}.jsonl; developers had to hand-write Python one-liners to parse nested JSONL structure
tags: [codex, trace, debug, mix-task, jsonl, elixir, developer-tooling]
date: 2026-03-19
---

## Problem

When debugging a stuck or failing Codex agent run, there was no structured way to
read the trace files at `log/traces/{issue_identifier}.jsonl`. Developers had to
hand-write Python one-liners to extract useful information.

The format is non-trivial: each JSONL line contains a top-level `raw` field that is
**itself a JSON-encoded string** (double-encoded), and the useful typed payload is
buried inside `params.item` after the second decode.

Two audiences need this tooling:
1. Humans debugging interactively
2. Codex agents using the `debug` skill during their own investigations

---

## Root Cause

The `SymphonyElixir.Codex.TraceLogger` module already wrote per-issue JSONL trace
files and exposed `trace_path/1` for path resolution, but no consumer tooling
existed. The double-encoding was a consequence of how the Codex SDK serializes its
message envelope — the outer record is a Symphony log entry, and the inner `raw`
value is the verbatim Codex event payload as a string. Without a known pattern, every
developer who needed to inspect a trace had to rediscover the double-decode pattern
from scratch.

---

## Solution

### 1. New Mix task: `mix trace.show`

**File:** `elixir/lib/mix/tasks/trace.show.ex`

Follows the same conventions as other Mix tasks in this repo (`OptionParser`,
`Mix.shell().info/error`, `Mix.raise` for errors).

```bash
# Full trace for an issue
mix trace.show GRE-8

# Trace from a specific workspace directory
mix trace.show GRE-8 --dir ~/code/greet/greet-88218/log/traces

# Only command executions
mix trace.show GRE-8 --filter commands

# Only agent messages
mix trace.show GRE-8 --filter agent

# Only errors (failed commands + turn_failed/cancelled)
mix trace.show GRE-8 --filter errors

# Last 20 events only
mix trace.show GRE-8 --tail 20
```

**Options:**

| Flag | Default | Description |
|------|---------|-------------|
| `ISSUE_KEY` | (required) | e.g. `GRE-8` |
| `--dir DIR` | `log/traces` (via `TraceLogger.trace_path/1`) | Trace directory |
| `--filter TYPE` | `all` | One of: `all`, `commands`, `agent`, `errors` |
| `--tail N` | (all) | Show last N events only |

### 2. Updated debug skill

**File:** `.codex/skills/debug/SKILL.md`

Added a "Trace Files (Full Message History)" section covering:
- How to use `mix trace.show`
- Raw `jq` fallbacks for environments where mix isn't available

---

## Key Code

### The double-decode pattern

```elixir
defp parse_line(line) do
  case Jason.decode(String.trim(line)) do
    {:ok, entry} ->
      event = entry["event"]
      timestamp = entry["timestamp"]
      raw = entry["raw"]

      item =
        if raw do
          case Jason.decode(raw) do
            {:ok, decoded} -> get_in(decoded, ["params", "item"])
            _ -> nil
          end
        end

      [%{event: event, timestamp: timestamp, item: item, entry: entry}]

    _ ->
      []
  end
end
```

The first `Jason.decode` reads the outer JSONL log record. The second decodes the
`raw` string value, which contains the verbatim Codex SDK event envelope.
`get_in/2` then extracts `params.item` — the typed payload.

### Filter logic

```elixir
defp matches_filter?(%{item: item, event: event}, filter) do
  case filter do
    "all"      -> true
    "commands" -> item_type(item) == "commandExecution"
    "agent"    -> item_type(item) == "agentMessage"
    "errors"   ->
      (item_type(item) == "commandExecution" and item["status"] == "failed") or
        event in ["turn_failed", "turn_cancelled"]
  end
end
```

### Item types handled

| `params.item.type` | Output format |
|--------------------|---------------|
| `commandExecution` | `[CMD status] command\n  output` |
| `agentMessage` | `[AGENT phase] text` |
| `dynamicToolCall` | `[TOOL name] success/failure` |
| turn events (`turn_failed`, etc.) | `[EVENT name]` |

---

## Prevention

**Format ownership rule:** Any new internal data format must ship with at least one
read tool before the format is considered complete. The implementation PR is
incomplete without a reader. Apply this as a PR checklist item.

**Document the format schema inline.** The writer module (`TraceLogger`) should
describe the exact JSONL shape — which fields are double-encoded, what `params.item`
contains, etc. When the schema lives next to the writer, future developers do not
have to reverse-engineer it.

**Advertise tooling.** Add `mix trace.show` and similar tasks to README or WORKFLOW.md
so they are discoverable. Tooling that is not visible doesn't get used.

---

## Gotchas

- **Malformed outer JSON:** A line written during a mid-write process kill will fail
  the first `Jason.decode`. The task skips silently (via `flat_map`) but this is
  recoverable — you'll see a gap in the output.

- **Malformed `raw` field:** The outer JSON may parse while the `raw` string is
  truncated. The inner decode returns `nil` for `item`; events with no `item` are
  displayed only if they carry a top-level `event` field.

- **Large files:** The task uses `File.stream!` for line-by-line streaming, so large
  traces won't blow memory.

- **Line endings:** `String.trim/1` is called on each line before parsing, handling
  `\r\n` on Windows-origin files.

- **The `raw` field is optional.** Some lines (e.g., session start/end lifecycle
  events) carry only top-level fields with no `raw`. These are still displayed as
  `[EVENT name]`.

---

## Maintenance

If the trace format changes:

1. **Top-level schema changes** (new/renamed fields): update the `parse_line/1`
   accessor keys.
2. **`raw` encoding changes** (switches from JSON string to inline object): update
   the inner decode step. This is the highest-risk change — a silent failure here
   drops all item data.
3. **`params.item` structure changes** (new item types): add a new `print_event/1`
   clause and a `matches_filter?/2` case.

---

## Related

- `elixir/lib/symphony_elixir/codex/trace_logger.ex` — the writer; `trace_path/1`
  is reused by `mix trace.show` for path resolution
- `elixir/lib/mix/tasks/trace.show.ex` — the task implementation
- `.codex/skills/debug/SKILL.md` — debug skill documentation including jq fallbacks
- `elixir/docs/logging.md` — logging conventions and required context fields
