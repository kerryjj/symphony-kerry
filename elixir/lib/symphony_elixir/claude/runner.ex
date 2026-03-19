defmodule SymphonyElixir.Claude.Runner do
  @moduledoc """
  Executes a single turn using the Claude CLI (--print --output-format stream-json).

  Spawns claude as an OS port, streams newline-delimited JSON events, and returns
  when the result event is received or a timeout/exit occurs.

  Completion is signalled by `{"type": "result", "subtype": "success"}`. Any other
  result subtype is treated as an error. Non-JSON lines are silently skipped.
  """

  require Logger

  @default_timeout_ms 3_600_000

  @spec run_turn(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def run_turn(workspace, prompt, opts \\ []) do
    command = Keyword.get(opts, :command, default_command())
    on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    full_cmd = "cd #{shell_escape(workspace)} && #{command} -p #{shell_escape(prompt)}"
    port = Port.open({:spawn, "bash -lc #{shell_escape(full_cmd)}"}, [:binary, :exit_status, line: 1_048_576])

    receive_loop(port, on_message, timeout_ms, "")
  end

  defp receive_loop(port, on_message, timeout_ms, pending) do
    receive do
      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(port, on_message, timeout_ms, pending <> chunk)

      {^port, {:data, {:eol, chunk}}} ->
        line = pending <> chunk

        case Jason.decode(line) do
          {:ok, %{"type" => "result", "subtype" => "success"} = event} ->
            on_message.(event)
            safe_close(port)
            :ok

          {:ok, %{"type" => "result"} = event} ->
            on_message.(event)
            safe_close(port)
            {:error, {:claude_result, event["subtype"], event}}

          {:ok, event} ->
            on_message.(event)
            receive_loop(port, on_message, timeout_ms, "")

          {:error, _} ->
            Logger.debug("Claude.Runner non-JSON line: #{inspect(line)}")
            receive_loop(port, on_message, timeout_ms, "")
        end

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, status}} ->
        {:error, {:exit_status, status}}
    after
      timeout_ms ->
        safe_close(port)
        {:error, :timeout}
    end
  end

  defp safe_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp default_command do
    SymphonyElixir.Config.settings!().claude.command
  end

  defp shell_escape(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
