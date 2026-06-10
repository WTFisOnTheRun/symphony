defmodule SymphonyElixir.ChildRunReadOnlyAdapterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ChildRunReadOnlyAdapter
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Linear.Issue

  @read_path "synthetic://dts41/context.md"

  defp parent_context do
    %{
      issue_identifier: "DTS-41",
      goal: "prove read-only child adapter",
      bounded_question: "Read only the named target and return bounded findings.",
      read_targets: [@read_path],
      source_refs: ["DTS-41 Goal Contract"],
      constraints: ["parent owns synthesis", "no capability flip"],
      parent_revision: "parent-r1",
      messages: ["must not be passed to child"],
      transcript: "secret transcript"
    }
  end

  defp issue do
    %Issue{
      id: "issue-dts-41",
      identifier: "DTS-41",
      title: "Read-only child adapter",
      description: "DTS-41 adapter proof",
      state: "Symphony Ready",
      url: "https://example.org/issues/DTS-41",
      labels: ["backend"]
    }
  end

  defp accepted_child_result do
    %{
      adapter_version: AppServer.readonly_child_adapter_version(),
      read_only_child: true,
      session_id: "child-thread-41-child-turn-41",
      thread_id: "child-thread-41",
      turn_id: "child-turn-41",
      result: :turn_completed
    }
  end

  test "exposes the explicit adapter version" do
    assert ChildRunReadOnlyAdapter.adapter_version() == "codex-app-server-readonly-child-thread-v0"
  end

  test "default run entry still requires explicit bounded paths" do
    assert_raise KeyError, fn ->
      ChildRunReadOnlyAdapter.run(parent_context(), issue())
    end
  end

  test "runs read-only child only after dispatcher gate accepts" do
    run_child = fn workspace, prompt, child_issue, opts ->
      assert workspace == "C:/workspaces/DTS-41"
      assert child_issue.identifier == "DTS-41"
      assert opts[:output_schema] == AppServer.readonly_child_output_schema()
      assert prompt =~ "Adapter: codex-app-server-readonly-child-thread-v0"
      assert prompt =~ @read_path
      refute prompt =~ "secret transcript"
      refute prompt =~ "must not be passed to child"

      {:ok, accepted_child_result()}
    end

    assert {:ok, proof} =
             ChildRunReadOnlyAdapter.run(parent_context(), issue(),
               workspace: "C:/workspaces/DTS-41",
               read_path: @read_path,
               remaining_warn_fuse_budget: 520_000,
               budget_source: :synthetic_fixture,
               run_child: run_child
             )

    assert proof.status == :readonly_child_completed
    assert proof.adapter_version == "codex-app-server-readonly-child-thread-v0"
    assert proof.spawn_real_child
    refute proof.proof_only
    refute proof.capability_enabled
    assert proof.child_session_id == "child-thread-41-child-turn-41"
    assert proof.child_thread_id == "child-thread-41"
    assert proof.child_turn_id == "child-turn-41"
    assert proof.parent_owns_synthesis
    assert proof.effective_tool_grant.read_only_only
    refute :messages in proof.child_input_keys
    refute :transcript in proof.child_input_keys

    assert Enum.any?(proof.trace, &(&1.event == :child_start && &1.attrs.spawn_real_child))
    assert Enum.any?(proof.trace, &(&1.event == :child_terminal_state && &1.attrs.state == :completed_readonly_child))
    assert Enum.any?(proof.trace, &(&1.event == :parent_synthesis && &1.attrs.owner == :parent_runner))
  end

  test "child runtime failure is returned as a read-only child failure" do
    run_child = fn _workspace, _prompt, _issue, _opts ->
      {:error, :child_runtime_failed}
    end

    assert {:error, {:readonly_child_failed, :child_runtime_failed}} =
             ChildRunReadOnlyAdapter.run(parent_context(), issue(),
               workspace: "C:/workspaces/DTS-41",
               read_path: @read_path,
               remaining_warn_fuse_budget: 520_000,
               budget_source: :synthetic_fixture,
               run_child: run_child
             )
  end

  test "dispatcher denial blocks before child start" do
    run_child = fn _workspace, _prompt, _issue, _opts ->
      flunk("child adapter should not be invoked when dispatcher rejects the request")
    end

    assert {:error, {:dispatcher_gate_blocked, proof}} =
             ChildRunReadOnlyAdapter.run(parent_context(), issue(),
               workspace: "C:/workspaces/DTS-41",
               read_path: @read_path,
               requested_tool: :git_commit,
               requested_tools: [:read_file, :git_commit],
               remaining_warn_fuse_budget: 520_000,
               budget_source: :synthetic_fixture,
               run_child: run_child
             )

    assert proof.status == :tool_denied
    assert proof.terminal_blocker
    refute proof.spawn_real_child
  end
end
