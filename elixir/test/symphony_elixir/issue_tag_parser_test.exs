defmodule SymphonyElixir.IssueTagParserTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.IssueTagParser

  describe "parse/1" do
    test "nil description returns nil backend" do
      assert %{backend: nil} = IssueTagParser.parse(nil)
    end

    test "description with no tags returns nil backend" do
      assert %{backend: nil} = IssueTagParser.parse("Fix the bug in the auth flow.")
    end

    test "[agent: claude] returns :claude" do
      assert %{backend: :claude} = IssueTagParser.parse("Some task\n[agent: claude]")
    end

    test "[agent: codex] returns :codex" do
      assert %{backend: :codex} = IssueTagParser.parse("Some task\n[agent: codex]")
    end

    test "[agent: CLAUDE] uppercase returns :claude" do
      assert %{backend: :claude} = IssueTagParser.parse("[agent: CLAUDE]")
    end

    test "[agent: Codex] mixed case returns :codex" do
      assert %{backend: :codex} = IssueTagParser.parse("[agent: Codex]")
    end

    test "[agent: gemini] invalid value returns nil backend" do
      assert %{backend: nil} = IssueTagParser.parse("[agent: gemini]")
    end

    test "extra whitespace inside tag is tolerated" do
      assert %{backend: :claude} = IssueTagParser.parse("[agent:  claude  ]")
    end

    test "trailing content inside tag is tolerated" do
      assert %{backend: :claude} = IssueTagParser.parse("[agent: claude, plan: docs/brainstorms/foo.md]")
    end

    test "tag mid-description with surrounding text is extracted" do
      description = """
      Implement the new feature.

      [agent: claude]

      See requirements doc for details.
      """

      assert %{backend: :claude} = IssueTagParser.parse(description)
    end

    test "empty string returns nil backend" do
      assert %{backend: nil} = IssueTagParser.parse("")
    end

    test "[skill: lfg] tag without agent tag returns nil backend (skill tag is agent-level concern)" do
      assert %{backend: nil} = IssueTagParser.parse("[skill: lfg] some description")
    end

    test "[plan: docs/foo.md] tag without agent tag returns nil backend" do
      assert %{backend: nil} = IssueTagParser.parse("[plan: docs/foo.md]")
    end
  end
end
