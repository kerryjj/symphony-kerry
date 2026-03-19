---
date: 2026-03-19
topic: multi-backend-agent-selection
---

# Multi-Backend Agent Selection

## Problem Frame

Symphony Elixir currently supports only Codex CLI as its agent backend. The WORKFLOW.md acts
as the outer orchestrator prompt — managing Linear state, workpad, PRs, and the full ticket
lifecycle. The agent running that prompt does the actual coding work using the `/lfg` skill.
Project owners want to choose per-ticket (or per-project) whether Codex CLI or Claude CLI
runs that WORKFLOW.md session. Both CLIs have the `ce:lfg` skill available. After execution,
a Linear label records which backend ran.

## Requirements

- R1. WORKFLOW.md frontmatter supports an `agent.default_backend` field accepting `codex`
  (default, backward-compatible) or `claude`.
- R2. A `[agent: <backend>]` tag in a Linear ticket's description body overrides the project
  default for that ticket. Valid values: `codex`, `claude`.
- R3. Both backends receive the **identical** rendered WORKFLOW.md prompt template. The only
  difference is which CLI binary Symphony invokes to run it.
- R4. WORKFLOW.md is updated to default to `/lfg` for the implementation phase. A
  `[skill: <name>]` tag in the ticket description overrides which skill is invoked (e.g.
  `[skill: ce:work]`, `[skill: feature-dev]`). A `[plan: <path>]` tag passes a specific
  requirements file to that skill. If neither tag is present, `/lfg` runs with the ticket
  description as context. All of this is handled inside the WORKFLOW.md prompt — not by
  Symphony infrastructure.
- R5. After an agent run completes, Symphony adds a Linear label matching the backend used
  (`codex` or `claude`) to the ticket.

## Success Criteria

- A ticket tagged `[agent: claude]` runs with Claude CLI against the same WORKFLOW.md prompt
  that Codex would have received; an untagged ticket uses `agent.default_backend`.
- Both Claude and Codex sessions default to `/lfg` for coding work; a `[skill: <name>]` tag
  in the description overrides which skill is used (enforced by WORKFLOW.md, not Symphony).
- A ticket with `[plan: docs/brainstorms/SYM-42-requirements.md]` in the description causes
  the agent to pass that file to the skill (the agent reads and acts on the tag itself).
- After any run, the ticket gains a `codex` or `claude` label reflecting which backend ran.
- Existing WORKFLOW.md files continue to work without changes (default_backend: codex).

## Scope Boundaries

- Only `codex` and `claude` are valid backend values; no other backends in scope.
- One WORKFLOW.md prompt covers both backends — no per-backend prompt split.
- Symphony does **not** parse `[skill: ...]` or `[plan: ...]` tags — those are entirely
  handled by the agent following WORKFLOW.md instructions.
- No Symphony dashboard UI changes for backend selection.
- Labels added post-run are observability only; they do not affect routing.

## Key Decisions

- **Routing via description tag, not Linear label**: Labels are applied after the run for
  observability. This prevents manual label management overhead and keeps routing intent
  co-located with the ticket content.
- **Identical prompt for both backends**: WORKFLOW.md is the outer orchestrator for both
  Codex and Claude. The backend choice is purely which CLI binary Symphony invokes —
  not a different prompt strategy.
- **Skill selection is a WORKFLOW.md concern, not a Symphony concern**: Both CLIs have
  `/lfg` available. WORKFLOW.md defaults to it and lets `[skill: <name>]` override it.
  Symphony doesn't know about skills at all.
- **`[skill: ...]` and `[plan: ...]` are agent-level concerns**: The agent reads
  `{{ issue.description }}` and acts on the tags. Symphony renders the template and invokes
  the CLI — nothing more. Any skill name is valid; the agent invokes it directly.
- **Default backend is `codex`**: Preserves full backward compatibility.

## Dependencies / Assumptions

- Linear API write access is already present (Symphony uses it for state transitions; the
  same access will apply labels).
- The `claude` CLI is available in the execution environment when the Claude backend is
  selected (same requirement as `codex` for Codex runs).
- Both `~/.codex` and `~/.claude` have the `compound-engineering` plugin installed, giving
  both CLIs access to the `/lfg` skill.
- The `codex` and `claude` Linear labels may need to be pre-created in the workspace
  (subject to Linear API behavior — see deferred questions).

## Outstanding Questions

### Resolve Before Planning

_(none — all blocking product decisions are resolved)_

### Deferred to Planning

- [Affects R3][Technical] Claude CLI session/turn management: does `--resume SESSION_ID`
  enable multi-turn continuation analogous to Codex `app-server`, or is each
  `claude --print` call stateless? This affects how `AgentRunner` manages Claude turns.
- [Affects R2][Needs research] What tag parsing approach (regex, structured parser) is most
  robust for extracting `agent:` from Linear ticket description bodies?
- [Affects R5][Needs research] Does the Linear API support creating labels on-the-fly if
  `codex`/`claude` labels don't exist yet, or must they be pre-created in the workspace?

## Next Steps

→ `/ce:plan` for updated implementation planning
