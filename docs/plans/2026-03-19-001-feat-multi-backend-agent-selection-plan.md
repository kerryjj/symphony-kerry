---
title: "feat: Multi-Backend Agent Selection (Codex + Claude)"
type: feat
status: active
date: 2026-03-19
origin: docs/brainstorms/2026-03-19-multi-backend-agent-selection-requirements.md
---

# feat: Multi-Backend Agent Selection (Codex + Claude)

## Overview

Allow Symphony to run a WORKFLOW.md session using either Codex CLI or Claude CLI. The WORKFLOW.md
is the outer orchestrator for both — managing Linear state, workpad, PRs, and ticket lifecycle.
The backend choice (Codex vs Claude) is specified via `[agent: claude]` in the ticket description
or via `agent.default_backend` in WORKFLOW.md frontmatter. Both backends use the identical
rendered prompt. After each run, a `codex` or `claude` label is added to the ticket.

The WORKFLOW.md itself is updated to instruct agents to use `/lfg` for the implementation phase
(both CLIs have the skill; this is a prompt-level concern, not infrastructure).

See origin: `docs/brainstorms/2026-03-19-multi-backend-agent-selection-requirements.md`

## Architecture

```
Symphony orchestrator (unchanged)
  │
  ├─ polls Linear for active tickets
  ├─ resolves backend: [agent: ...] tag → or → agent.default_backend → or → :codex
  │
  └─ AgentRunner.run/3
       │
       ├─ :codex → existing AppServer path (codex app-server, JSON-RPC)
       │             prompt: rendered WORKFLOW.md template
       │
       └─ :claude → new Claude.Runner path (claude --print, stream-json)
                     prompt: same rendered WORKFLOW.md template
       │
       └─ (after run) Tracker.add_label_to_issue(issue.id, "codex" | "claude")
```

The WORKFLOW.md prompt itself instructs the agent (Codex or Claude) to use `/lfg` for
implementation, and to look for a `[plan: <path>]` tag in the ticket description.
Symphony has no knowledge of `/lfg` or plan files.

## Changes Required

Five coordinated changes:

1. **Config**: Add `agent.default_backend` to `Config.Schema.Agent`; add `Claude` embedded schema
2. **Tag parser**: `SymphonyElixir.IssueTagParser` — extracts `[agent: ...]` from ticket descriptions
3. **Claude runner**: `SymphonyElixir.Claude.Runner` — invokes `claude --print --output-format stream-json`, streams output, handles completion
4. **AgentRunner routing**: Resolve backend from tag or config default; dispatch to Codex or Claude runner
5. **Linear label write + post-run labeling**: `add_label_to_issue/2` in Tracker + Adapter + Client; called after every run

Plus: **WORKFLOW.md update** to instruct agents to use `/lfg` with any `[plan: ...]` tag.

## Technical Notes

### Claude CLI Invocation

```bash
claude --print --output-format stream-json -p "<rendered WORKFLOW.md prompt>"
```

- `--print` = non-interactive, exits after completion
- `--output-format stream-json` = newline-delimited JSON events on stdout
- Completion signalled by `{"type": "result", "subtype": "success"}` (or error variants)
- Stateless: each `claude --print` call is independent; no session to manage

The `/lfg` skill runs autonomously inside that Claude session and handles its own
multi-step loop (plan → deepen → work → review). Symphony's turn-continuation loop
still applies: if the issue is still active after Claude exits, Symphony re-invokes.

### Tag Parsing

Simple regex on `issue.description`:
```elixir
~r/\[agent:\s*(codex|claude)[^\]]*\]/i
```
Case-insensitive, whitespace-tolerant, and permissive of any trailing content before `]`
(e.g. `[agent: claude, plan: foo.md]` still matches). No other tags are parsed by Symphony.

### Linear Label Write

Labels require UUIDs. Strategy:
1. Fetch team labels, find by name
2. If not found, create with `issueLabelCreate` (default color)
3. Merge with current issue label IDs
4. `issueUpdate` with merged `labelIds`

Best-effort: label failure logs a warning and never fails the run.

## Acceptance Criteria

- [ ] `[agent: claude]` in ticket description → Claude CLI runs the WORKFLOW.md session
- [ ] No tag + `agent.default_backend: codex` (or omitted) → Codex runs as before
- [ ] `agent.default_backend: claude` in WORKFLOW.md → Claude is the project default
- [ ] Both backends receive identical rendered WORKFLOW.md prompt
- [ ] After any run, ticket gains `codex` or `claude` label
- [ ] Existing WORKFLOW.md files with no `default_backend` continue to work unchanged
- [ ] WORKFLOW.md defaults to `/lfg` for implementation; `[skill: <name>]` overrides the skill; `[plan: <path>]` passes a file to the skill
- [ ] `IssueTagParser` unit tests: no tag, `[agent: claude]`, `[agent: codex]`, uppercase, invalid value, extra whitespace, trailing content in tag
- [ ] `Claude.Runner` unit tests: success, error result, port exit failure, timeout
- [ ] `AgentRunner` routing tests: `[agent: claude]` dispatches to Claude path; no tag + codex default dispatches to Codex path; `agent.default_backend: claude` routes to Claude
- [ ] `Linear.Adapter.add_label_to_issue` unit tests

---

## Phase 1: Config Schema Extension

**File:** `elixir/lib/symphony_elixir/config/schema.ex`

### 1a. Add `default_backend` to `Agent` schema (lines ~123–151)

```elixir
# In defmodule Agent, embedded_schema block:
field(:default_backend, :string, default: "codex")

# In Agent.changeset/2, add to cast list:
|> cast(attrs, [..., :default_backend], empty_values: [])
|> validate_inclusion(:default_backend, ["codex", "claude"])
```

### 1b. Add new `Claude` embedded schema (alongside existing `Codex` module)

```elixir
defmodule Claude do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:command, :string, default: "claude --print --output-format stream-json")
  end

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:command], empty_values: [])
    |> validate_required([:command])
  end
end
```

### 1c. Wire into root schema

```elixir
# In root embedded_schema (alongside :codex):
embeds_one(:claude, Claude, on_replace: :update, defaults_to_struct: true)

# In root changeset/1 (alongside cast_embed :codex):
|> cast_embed(:claude, with: &Claude.changeset/2)
```

**WORKFLOW.md usage** (new optional fields):
```yaml
agent:
  default_backend: claude   # optional; defaults to "codex"

claude:
  command: claude --print --output-format stream-json  # optional
```

---

## Phase 2: Issue Tag Parser

**New file:** `elixir/lib/symphony_elixir/issue_tag_parser.ex`

```elixir
defmodule SymphonyElixir.IssueTagParser do
  @moduledoc """
  Parses [agent: ...] tags from Linear issue description bodies.
  """

  @agent_tag ~r/\[agent:\s*(codex|claude)[^\]]*\]/i

  @type result :: %{backend: :codex | :claude | nil}

  @spec parse(String.t() | nil) :: result()
  def parse(nil), do: %{backend: nil}
  def parse(description) when is_binary(description) do
    case Regex.run(@agent_tag, description, capture: :all_but_first) do
      [backend_str] -> %{backend: backend_str |> String.downcase() |> String.to_atom()}
      nil -> %{backend: nil}
    end
  end
end
```

**New test file:** `elixir/test/symphony_elixir/issue_tag_parser_test.exs`

Test cases:
- `nil` → `%{backend: nil}`
- No tags → `%{backend: nil}`
- `[agent: claude]` → `%{backend: :claude}`
- `[agent: codex]` → `%{backend: :codex}`
- `[agent: CLAUDE]` (uppercase) → `%{backend: :claude}`
- `[agent: gemini]` (invalid) → `%{backend: nil}`
- `[agent:  claude  ]` (extra whitespace) → `%{backend: :claude}`
- `[agent: claude, plan: docs/brainstorms/foo.md]` (trailing content) → `%{backend: :claude}`
- Tag mid-description with surrounding text → correctly extracted

---

## Phase 3: Claude Runner

**New file:** `elixir/lib/symphony_elixir/claude/runner.ex`

```elixir
defmodule SymphonyElixir.Claude.Runner do
  @moduledoc """
  Executes a single turn using the Claude CLI (--print --output-format stream-json).
  Spawns claude as an OS port, streams newline-delimited JSON events, returns on completion.
  """

  require Logger

  @spec run_turn(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def run_turn(workspace, prompt, opts \\ []) do
    command  = Keyword.get(opts, :command, default_command())
    on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)
    timeout_ms = Keyword.get(opts, :timeout_ms, 3_600_000)

    full_cmd = "cd #{shell_escape(workspace)} && #{command} -p #{shell_escape(prompt)}"
    port = Port.open({:spawn, "bash -lc #{shell_escape(full_cmd)}"}, [:binary, :exit_status, line: 65536])

    receive_loop(port, on_message, timeout_ms)
  end

  defp receive_loop(port, on_message, timeout_ms) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(line) do
          {:ok, %{"type" => "result", "subtype" => "success"} = event} ->
            on_message.(event)
            Port.close(port)
            :ok

          {:ok, %{"type" => "result"} = event} ->
            on_message.(event)
            Port.close(port)
            {:error, {:claude_result, event["subtype"], event}}

          {:ok, event} ->
            on_message.(event)
            receive_loop(port, on_message, timeout_ms)

          {:error, _} ->
            Logger.debug("Claude.Runner non-JSON line: #{inspect(line)}")
            receive_loop(port, on_message, timeout_ms)
        end

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, status}} ->
        {:error, {:exit_status, status}}

    after
      timeout_ms ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  defp default_command do
    SymphonyElixir.Config.settings!().claude.command
  end

  defp shell_escape(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
```

**New test file:** `elixir/test/symphony_elixir/claude/runner_test.exs`

Test cases:
- Success: port emits `{"type":"result","subtype":"success"}` → `:ok`
- Error result: port emits `{"type":"result","subtype":"error_max_turns"}` → `{:error, ...}`
- Non-JSON lines are skipped; loop continues
- Port exit 0 without result event → `:ok`
- Port exit non-zero → `{:error, {:exit_status, status}}`
- Timeout → `{:error, :timeout}`

---

## Phase 4: AgentRunner Routing

**File:** `elixir/lib/symphony_elixir/agent_runner.ex`

### 4a. Add aliases

```elixir
alias SymphonyElixir.Claude.Runner, as: ClaudeRunner
alias SymphonyElixir.IssueTagParser
```

### 4b. Add backend resolution

```elixir
defp resolve_backend(issue) do
  case IssueTagParser.parse(issue.description).backend do
    nil -> config_default_backend()
    backend -> backend
  end
end

defp config_default_backend do
  case Config.settings!().agent.default_backend do
    "claude" -> :claude
    _ -> :codex
  end
end
```

### 4c. Replace hardcoded `run_codex_turns` call in `run_on_worker_host/4`

Current (line ~54):
```elixir
run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
```

Replace with:
```elixir
backend = resolve_backend(issue)
result = dispatch_run(backend, workspace, issue, codex_update_recipient, opts, worker_host)
add_backend_label(issue, backend)
result
```

### 4d. Add dispatch and Claude turn functions

```elixir
defp dispatch_run(:codex, workspace, issue, codex_update_recipient, opts, worker_host) do
  run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
end

defp dispatch_run(:claude, workspace, issue, codex_update_recipient, opts, _worker_host) do
  run_claude_turns(workspace, issue, codex_update_recipient, opts)
end

defp run_claude_turns(workspace, issue, codex_update_recipient, opts) do
  max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
  issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
  command = Config.settings!().claude.command

  do_run_claude_turns(workspace, issue, codex_update_recipient, opts, issue_state_fetcher, command, 1, max_turns)
end

defp do_run_claude_turns(workspace, issue, codex_update_recipient, opts, issue_state_fetcher, command, turn_number, max_turns) do
  prompt = build_claude_turn_prompt(issue, opts, turn_number, max_turns)

  with :ok <- ClaudeRunner.run_turn(workspace, prompt,
         command: command,
         on_message: codex_message_handler(codex_update_recipient, issue)) do
    Logger.info("Completed Claude turn for #{issue_context(issue)} turn=#{turn_number}/#{max_turns}")

    case continue_with_issue?(issue, issue_state_fetcher) do
      {:continue, refreshed_issue} when turn_number < max_turns ->
        do_run_claude_turns(workspace, refreshed_issue, codex_update_recipient, opts, issue_state_fetcher, command, turn_number + 1, max_turns)
      {:continue, _} -> :ok
      {:done, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end

defp build_claude_turn_prompt(issue, opts, 1, _max_turns) do
  PromptBuilder.build_prompt(issue, opts)
end

defp build_claude_turn_prompt(_issue, _opts, turn_number, max_turns) do
  """
  Continuation guidance:

  - The previous Claude turn completed normally, but the Linear issue is still in an active state.
  - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
  - Resume from the current workspace and workpad state instead of restarting from scratch.
  """
end

defp add_backend_label(issue, backend) do
  label_name = Atom.to_string(backend)
  case Tracker.add_label_to_issue(issue.id, label_name) do
    :ok -> :ok
    {:error, reason} ->
      Logger.warning("Failed to add label #{label_name} to #{issue_context(issue)}: #{inspect(reason)}")
  end
end
```

**Note on placement of `add_backend_label`:** It must be called in the `try...after` block of
`run_on_worker_host/4` — specifically after the dispatch result is captured but outside the
`after` clause (which only runs hooks). Best-effort: label failure never propagates.

---

## Phase 5: Linear Label Write

### 5a. `Linear.Client` — new GraphQL operations

**File:** `elixir/lib/symphony_elixir/linear/client.ex`

Add these operations following the existing pattern (module-level query strings + public functions):

```elixir
# Query: fetch issue's team ID and current label IDs
@fetch_issue_labels_query """
  query SymphonyFetchIssueLabels($id: String!) {
    issue(id: $id) {
      team { id }
      labels { nodes { id } }
    }
  }
"""

# Query: fetch labels for a team
@fetch_team_labels_query """
  query SymphonyFetchTeamLabels($teamId: String!) {
    issueLabels(filter: { team: { id: { eq: $teamId } } }) {
      nodes { id name }
    }
  }
"""

# Mutation: create a label
@create_label_mutation """
  mutation SymphonyCreateLabel($teamId: String!, $name: String!, $color: String!) {
    issueLabelCreate(input: { teamId: $teamId, name: $name, color: $color }) {
      issueLabel { id name }
      success
    }
  }
"""

# Mutation: update issue labels
@update_issue_labels_mutation """
  mutation SymphonyUpdateIssueLabels($id: String!, $labelIds: [String!]!) {
    issueUpdate(id: $id, input: { labelIds: $labelIds }) {
      success
    }
  }
"""
```

Add public functions:

```elixir
@spec add_label_to_issue(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
def add_label_to_issue(api_key, issue_id, label_name) do
  with {:ok, %{"team" => %{"id" => team_id}, "labels" => %{"nodes" => label_nodes}}} <-
         fetch_issue_label_info(api_key, issue_id),
       {:ok, label_id} <- ensure_label_exists(api_key, team_id, label_name),
       current_ids = Enum.map(label_nodes, & &1["id"]),
       false <- label_id in current_ids,  # skip if already labelled
       {:ok, _} <- graphql(api_key, @update_issue_labels_mutation,
                     %{"id" => issue_id, "labelIds" => Enum.uniq([label_id | current_ids])}) do
    :ok
  else
    true -> :ok  # already had the label
    {:error, reason} -> {:error, reason}
  end
end

defp fetch_issue_label_info(api_key, issue_id) do
  case graphql(api_key, @fetch_issue_labels_query, %{"id" => issue_id}) do
    {:ok, %{"issue" => issue}} -> {:ok, issue}
    {:ok, _} -> {:error, :issue_not_found}
    error -> error
  end
end

defp ensure_label_exists(api_key, team_id, label_name) do
  with {:ok, %{"issueLabels" => %{"nodes" => labels}}} <-
         graphql(api_key, @fetch_team_labels_query, %{"teamId" => team_id}) do
    case Enum.find(labels, &(String.downcase(&1["name"]) == String.downcase(label_name))) do
      %{"id" => id} ->
        {:ok, id}
      nil ->
        create_label(api_key, team_id, label_name)
    end
  end
end

defp create_label(api_key, team_id, label_name) do
  case graphql(api_key, @create_label_mutation,
         %{"teamId" => team_id, "name" => label_name, "color" => "#6366f1"}) do
    {:ok, %{"issueLabelCreate" => %{"issueLabel" => %{"id" => id}}}} -> {:ok, id}
    {:ok, _} -> {:error, :label_create_failed}
    error -> error
  end
end
```

### 5b. `Tracker` behaviour

**File:** `elixir/lib/symphony_elixir/tracker.ex`

Add callback and dispatch function:

```elixir
@callback add_label_to_issue(issue_id :: String.t(), label_name :: String.t()) ::
  :ok | {:error, term()}

@spec add_label_to_issue(String.t(), String.t()) :: :ok | {:error, term()}
def add_label_to_issue(issue_id, label_name) do
  adapter().add_label_to_issue(issue_id, label_name)
end
```

### 5c. `Linear.Adapter`

**File:** `elixir/lib/symphony_elixir/linear/adapter.ex`

```elixir
@impl SymphonyElixir.Tracker
def add_label_to_issue(issue_id, label_name) do
  Client.add_label_to_issue(Config.settings!().tracker.api_key, issue_id, label_name)
end
```

### 5d. `Tracker.Memory` (test stub)

**File:** `elixir/lib/symphony_elixir/tracker/memory.ex`

```elixir
@impl SymphonyElixir.Tracker
def add_label_to_issue(_issue_id, _label_name), do: :ok
```

---

## Phase 6: WORKFLOW.md Update

**File:** `elixir/WORKFLOW.md`

### 6a. Add skill-dispatch instructions to the execution phase

In the **Step 2: Execution phase** section, replace the current "Implement against the
hierarchical TODOs" guidance with a skill-dispatch block. Insert after step 4 (around line 204):

```markdown
## Skill dispatch for implementation

Use a skill to handle the implementation phase. Determine the skill as follows:

1. If the ticket description contains `[skill: <name>]`, use that skill.
2. Otherwise, default to `/lfg`.

Then determine the input:
- If the ticket description contains `[plan: <path>]`, pass the content of that file
  as the skill argument (path is relative to the workspace root).
- Otherwise, pass the ticket title and description as the skill argument.

Examples:
- No tags → `/lfg <title>: <description>`
- `[skill: ce:work]` + `[plan: docs/plans/SYM-42-plan.md]` → `/ce:work docs/plans/SYM-42-plan.md`
- `[skill: feature-dev]` → `/feature-dev <title>: <description>`

After the skill completes, resume this workflow: update the workpad, verify the PR exists,
run the PR feedback sweep, and move to `Human Review` when the completion bar is met.
```

### 6b. Update frontmatter comments

```yaml
agent:
  max_concurrent_agents: 10
  max_turns: 20
  # default_backend: codex  # "codex" or "claude" — override per-ticket with [agent: <value>] in description

# claude:
#   command: claude --print --output-format stream-json
```

---

## Dependencies & Risks

| Risk | Mitigation |
|------|-----------|
| `claude` CLI not in worker PATH | `Claude.Runner` port spawn fails; error propagates through existing AgentRunner worker-host failover |
| Linear `issueLabelCreate` requires specific permissions | `add_backend_label` is best-effort; warns and continues |
| `claude --print` stream format changes | Parser is lenient — non-JSON lines are skipped; only `type: "result"` drives completion |
| `PromptBuilder.build_prompt/2` renders a very large prompt | Same concern as Codex today; no new risk |
| `validate_inclusion` added to `agent.default_backend` | Existing WORKFLOW.md files with no `default_backend` field are unaffected (field has default `"codex"`) |

## Sources & References

### Origin

- **Origin document:** [docs/brainstorms/2026-03-19-multi-backend-agent-selection-requirements.md](../brainstorms/2026-03-19-multi-backend-agent-selection-requirements.md)
  - Key decisions: identical prompt for both backends; `/lfg` is WORKFLOW.md's concern not Symphony's; `[plan: ...]` handled by agent not infrastructure; labels are observability-only

### Internal References

- `AgentRunner`: `elixir/lib/symphony_elixir/agent_runner.ex`
- `AppServer` (Codex, for contrast): `elixir/lib/symphony_elixir/codex/app_server.ex`
- `Config.Schema`: `elixir/lib/symphony_elixir/config/schema.ex`
- `PromptBuilder`: `elixir/lib/symphony_elixir/prompt_builder.ex`
- `Linear.Adapter`: `elixir/lib/symphony_elixir/linear/adapter.ex`
- `Linear.Client`: `elixir/lib/symphony_elixir/linear/client.ex`
- `Tracker` behaviour: `elixir/lib/symphony_elixir/tracker.ex`
- `Tracker.Memory`: `elixir/lib/symphony_elixir/tracker/memory.ex`
