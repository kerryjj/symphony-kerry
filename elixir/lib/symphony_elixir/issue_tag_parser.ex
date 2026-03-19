defmodule SymphonyElixir.IssueTagParser do
  @moduledoc """
  Parses [agent: ...] tags from Linear issue description bodies.

  Only `[agent: ...]` is parsed by Symphony. Tags like `[skill: ...]` and
  `[plan: ...]` are passed through to the agent via the rendered WORKFLOW.md
  prompt and are handled by the agent itself.
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
