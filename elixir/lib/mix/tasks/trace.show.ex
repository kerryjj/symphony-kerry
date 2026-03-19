defmodule Mix.Tasks.Trace.Show do
  use Mix.Task

  @shortdoc "Display formatted events from a Codex trace file"

  @moduledoc """
  Reads and formats events from a Codex trace JSONL file.

  Usage:

      mix trace.show ISSUE_KEY
      mix trace.show GRE-8 --dir ~/code/greet/greet-88218/log/traces
      mix trace.show GRE-8 --filter commands
      mix trace.show GRE-8 --filter errors
      mix trace.show GRE-8 --tail 20

  Options:

    --dir DIR       Trace directory (default: log/traces)
    --filter TYPE   Filter events: all (default), commands, agent, errors
    --tail N        Show last N events only
  """

  alias SymphonyElixir.Codex.TraceLogger

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [dir: :string, filter: :string, tail: :integer, help: :boolean],
        aliases: [h: :help]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      argv == [] ->
        Mix.raise("Usage: mix trace.show ISSUE_KEY [--dir DIR] [--filter TYPE] [--tail N]")

      true ->
        [issue_key | _] = argv
        show_trace(issue_key, opts)
    end
  end

  defp show_trace(issue_key, opts) do
    path =
      if dir = opts[:dir] do
        safe = String.replace(issue_key, ~r/[^A-Za-z0-9_\-]/, "_")
        Path.join([dir, "#{safe}.jsonl"])
      else
        TraceLogger.trace_path(issue_key)
      end

    unless File.exists?(path) do
      Mix.raise("Trace file not found: #{path}")
    end

    filter = opts[:filter] || "all"

    unless filter in ~w(all commands agent errors) do
      Mix.raise("Invalid --filter value: #{inspect(filter)}. Must be one of: all, commands, agent, errors")
    end

    events =
      path
      |> File.stream!()
      |> Enum.flat_map(&parse_line/1)
      |> Enum.filter(&matches_filter?(&1, filter))

    events =
      case opts[:tail] do
        nil -> events
        n -> Enum.take(events, -n)
      end

    Enum.each(events, &print_event/1)
  end

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

  defp matches_filter?(%{item: item, event: event}, filter) do
    case filter do
      "all" ->
        true

      "commands" ->
        item_type(item) == "commandExecution"

      "agent" ->
        item_type(item) == "agentMessage"

      "errors" ->
        (item_type(item) == "commandExecution" and item["status"] == "failed") or
          event in ["turn_failed", "turn_cancelled"]
    end
  end

  defp item_type(nil), do: nil
  defp item_type(item), do: item["type"]

  defp print_event(%{item: nil, event: event, timestamp: ts}) when event != nil do
    Mix.shell().info("[EVENT #{event}]#{format_ts(ts)}")
  end

  defp print_event(%{item: %{"type" => "commandExecution"} = item, timestamp: ts}) do
    status = item["status"] || "unknown"
    command = item["command"] || ""
    output = item["aggregatedOutput"] || ""
    Mix.shell().info("[CMD #{status}]#{format_ts(ts)} #{command}")

    if output != "" do
      output
      |> String.split("\n")
      |> Enum.each(fn line -> Mix.shell().info("  #{line}") end)
    end
  end

  defp print_event(%{item: %{"type" => "agentMessage"} = item, timestamp: ts}) do
    phase = item["phase"] || "unknown"
    text = item["text"] || ""
    Mix.shell().info("[AGENT #{phase}]#{format_ts(ts)} #{text}")
  end

  defp print_event(%{item: %{"type" => "dynamicToolCall"} = item, timestamp: ts}) do
    name = item["name"] || item["toolName"] || "unknown"
    status = if item["error"], do: "failure", else: "success"
    Mix.shell().info("[TOOL #{name}] #{status}#{format_ts(ts)}")
  end

  defp print_event(%{item: item, event: event, timestamp: ts}) when not is_nil(item) do
    type = item["type"] || "unknown"
    Mix.shell().info("[#{String.upcase(type)} event=#{event}]#{format_ts(ts)}")
  end

  defp print_event(_), do: :ok

  defp format_ts(nil), do: ""
  defp format_ts(ts), do: " (#{ts})"
end
