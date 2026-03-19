defmodule SymphonyElixir.Claude.RunnerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Claude.Runner

  @workspace System.tmp_dir!()

  # The Runner appends ` -p <shell_escaped_prompt>` to the command. These tests
  # use shell scripts written to temp files so the command ignores extra arguments.

  defp write_script!(test_root, name, body) do
    path = Path.join(test_root, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  setup do
    test_root =
      Path.join(System.tmp_dir!(), "runner-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(test_root)
    on_exit(fn -> File.rm_rf(test_root) end)
    %{test_root: test_root}
  end

  test "success: result event with subtype success returns :ok", %{test_root: test_root} do
    script = write_script!(test_root, "claude", ~s(printf '{"type":"result","subtype":"success"}\\n'))
    assert :ok = Runner.run_turn(@workspace, "some prompt", command: script)
  end

  test "success: on_message callback receives each event", %{test_root: test_root} do
    events = :ets.new(:runner_test_events, [:public, :bag])

    script =
      write_script!(test_root, "claude", """
      printf '{"type":"text","text":"hello"}\\n'
      printf '{"type":"result","subtype":"success"}\\n'
      """)

    Runner.run_turn(@workspace, "some prompt",
      command: script,
      on_message: fn event -> :ets.insert(events, {:event, event}) end
    )

    received = :ets.tab2list(events) |> Enum.map(fn {:event, e} -> e["type"] end) |> Enum.sort()
    assert received == ["result", "text"]
  end

  test "error result: non-success subtype returns {:error, {:claude_result, subtype, event}}", %{test_root: test_root} do
    subtype = "error_max_turns"

    script =
      write_script!(test_root, "claude", ~s(printf '{"type":"result","subtype":"#{subtype}"}\\n'))

    assert {:error, {:claude_result, ^subtype, _event}} =
             Runner.run_turn(@workspace, "some prompt", command: script)
  end

  test "non-JSON lines are skipped and loop continues to success", %{test_root: test_root} do
    script =
      write_script!(test_root, "claude", """
      printf 'not json at all\\n'
      printf '{"type":"result","subtype":"success"}\\n'
      """)

    assert :ok = Runner.run_turn(@workspace, "some prompt", command: script)
  end

  test "port exit 0 without a result event returns :ok", %{test_root: test_root} do
    script = write_script!(test_root, "claude", "exit 0")
    assert :ok = Runner.run_turn(@workspace, "some prompt", command: script)
  end

  test "port exit non-zero returns {:error, {:exit_status, status}}", %{test_root: test_root} do
    script = write_script!(test_root, "claude", "exit 42")
    assert {:error, {:exit_status, 42}} = Runner.run_turn(@workspace, "some prompt", command: script)
  end

  test "timeout returns {:error, :timeout}", %{test_root: test_root} do
    script = write_script!(test_root, "claude", "sleep 60")
    assert {:error, :timeout} = Runner.run_turn(@workspace, "some prompt", command: script, timeout_ms: 50)
  end
end
