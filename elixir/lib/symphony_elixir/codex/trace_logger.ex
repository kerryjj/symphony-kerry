defmodule SymphonyElixir.Codex.TraceLogger do
  @moduledoc """
  Appends every Codex on_message event to a per-issue JSONL trace file at
  log/traces/{identifier}.jsonl so full session history can be replayed later.
  """

  @default_traces_dir "log/traces"

  @spec log(map(), String.t()) :: :ok
  def log(message, identifier) do
    path = trace_path(identifier)
    :ok = File.mkdir_p(Path.dirname(path))

    line =
      message
      |> serializable()
      |> Jason.encode!()

    File.write(path, line <> "\n", [:append])
    :ok
  end

  @spec trace_path(String.t()) :: Path.t()
  def trace_path(identifier) do
    dir = Application.get_env(:symphony_elixir, :traces_dir, @default_traces_dir)
    safe = String.replace(identifier, ~r/[^A-Za-z0-9_\-]/, "_")
    Path.join([dir, "#{safe}.jsonl"])
  end

  # Convert the message map to something Jason can encode — strip any non-serialisable
  # values (PIDs, ports, references) and keep the raw JSON string when present.
  defp serializable(message) when is_map(message) do
    message
    |> Map.take([:event, :timestamp, :raw, :payload, :reason, :session_id, :thread_id, :turn_id, :usage])
    |> Map.new(fn {k, v} -> {k, encode_value(v)} end)
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp encode_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_value(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp encode_value(v) when is_atom(v), do: Atom.to_string(v)
  defp encode_value(v) when is_map(v) or is_list(v), do: v
  defp encode_value(_), do: nil
end
