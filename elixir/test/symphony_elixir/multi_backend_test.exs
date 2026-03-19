defmodule SymphonyElixir.MultiBackendTest do
  use SymphonyElixir.TestSupport

  # Tests for the multi-backend agent selection feature:
  # - Config schema extension (default_backend, Claude embedded schema)
  # - AgentRunner backend routing

  describe "config: agent.default_backend" do
    test "defaults to codex when not specified" do
      write_workflow_file!(Workflow.workflow_file_path())
      assert Config.settings!().agent.default_backend == "codex"
    end

    test "accepts claude as a valid value" do
      write_workflow_file!(Workflow.workflow_file_path(), default_backend: "claude")
      assert Config.settings!().agent.default_backend == "claude"
    end

    test "rejects invalid backend values" do
      write_workflow_file!(Workflow.workflow_file_path(), default_backend: "gemini")
      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "agent.default_backend"
    end
  end

  describe "config: claude embedded schema" do
    test "has a default command" do
      write_workflow_file!(Workflow.workflow_file_path())
      command = Config.settings!().claude.command
      assert is_binary(command)
      assert command =~ "claude"
    end

    test "accepts a custom claude command" do
      write_workflow_file!(Workflow.workflow_file_path(), claude_command: "my-claude --print")
      assert Config.settings!().claude.command == "my-claude --print"
    end
  end

  describe "AgentRunner routing" do
    setup do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-multi-backend-#{System.unique_integer([:positive])}"
        )

      workspace_root = Path.join(test_root, "workspaces")
      template_repo = Path.join(test_root, "source")
      File.mkdir_p!(workspace_root)
      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      on_exit(fn -> File.rm_rf(test_root) end)

      %{workspace_root: workspace_root, test_root: test_root}
    end

    test "issue with [agent: claude] description routes to Claude backend", %{workspace_root: workspace_root, test_root: test_root} do
      fake_claude = Path.join(test_root, "fake-claude")

      File.write!(fake_claude, """
      #!/bin/sh
      printf '{"type":"result","subtype":"success"}\\n'
      """)

      File.chmod!(fake_claude, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        claude_command: "#{fake_claude} --print --output-format stream-json"
      )

      issue = %Issue{
        id: "issue-claude-routing",
        identifier: "SYM-1",
        title: "Test Claude routing",
        description: "[agent: claude]\nImplement the feature.",
        state: "In Progress",
        url: "https://example.org/issues/SYM-1",
        labels: []
      }

      # Returns :ok when Claude runner completes successfully
      assert :ok = AgentRunner.run(issue)
    end

    test "issue without agent tag routes to Codex backend (default)", %{workspace_root: workspace_root, test_root: test_root} do
      fake_codex = Path.join(test_root, "fake-codex")

      File.write!(fake_codex, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}';;
          2) ;;
          3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1"}}}';;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0;;
          *) ;;
        esac
      done
      """)

      File.chmod!(fake_codex, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{fake_codex} app-server"
      )

      issue = %Issue{
        id: "issue-codex-routing",
        identifier: "SYM-2",
        title: "Test Codex routing",
        description: "No agent tag — should use default (codex).",
        state: "In Progress",
        url: "https://example.org/issues/SYM-2",
        labels: []
      }

      assert :ok = AgentRunner.run(issue)
    end

    test "agent.default_backend: claude in config routes to Claude when no tag present", %{workspace_root: workspace_root, test_root: test_root} do
      fake_claude = Path.join(test_root, "fake-claude-default")

      File.write!(fake_claude, """
      #!/bin/sh
      printf '{"type":"result","subtype":"success"}\\n'
      """)

      File.chmod!(fake_claude, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        default_backend: "claude",
        claude_command: "#{fake_claude} --print --output-format stream-json"
      )

      issue = %Issue{
        id: "issue-claude-default",
        identifier: "SYM-3",
        title: "Test Claude default backend",
        description: "No agent tag — should use default (claude from config).",
        state: "In Progress",
        url: "https://example.org/issues/SYM-3",
        labels: []
      }

      assert :ok = AgentRunner.run(issue)
    end
  end
end
