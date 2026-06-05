defmodule SymphonyElixir.ChildRunDispatcherTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ChildRunDispatcher

  @synthetic_path "synthetic://dts39/context.md"

  defp parent_context(read_path \\ @synthetic_path) do
    %{
      issue_identifier: "DTS-39",
      goal: "proof-only read-only child-run slice",
      bounded_question: "Read only the named target and return a bounded finding.",
      read_targets: [read_path],
      source_refs: ["DTS-39 Goal Contract"],
      constraints: ["parent owns synthesis", "no capability flip"],
      parent_revision: "r1",
      messages: ["not inherited by child"],
      transcript: "protected diagnostic only"
    }
  end

  defp runner_budget_opts do
    [remaining_warn_fuse_budget: 520_000, budget_source: :synthetic_fixture]
  end

  defp with_real_read_fixture(context) do
    path =
      Path.join([
        System.tmp_dir!(),
        "symphony-child-run-#{System.unique_integer([:positive])}.txt"
      ])

    File.write!(path, "DTS-39 portable read-only proof fixture")

    try do
      context.(path)
    after
      File.rm(path)
    end
  end

  test "prepare returns proof-only contract without spawning child" do
    assert {:ok, prepared} = ChildRunDispatcher.prepare(parent_context())

    assert prepared.status == :prepared_proof_only
    assert prepared.child_input.issue_identifier == "DTS-39"
    assert prepared.effective_tool_grant.read_only_only
    assert prepared.memory_policy.persistent_child_memory == false
    refute prepared.spawn_real_child
  end

  test "Stage 1 synthetic/local proof permits read-only attempt without spawning child" do
    assert {:ok, proof} =
             ChildRunDispatcher.execute_stage1(parent_context(),
               read_path: @synthetic_path,
               requested_tool: :read_file
             )

    assert proof.status == :readonly_allowed
    assert proof.stage == :synthetic_local
    assert proof.proof_only
    refute proof.capability_enabled
    refute proof.spawn_real_child
    assert proof.parent_owns_synthesis
    assert :read_file in proof.effective_tool_grant.allowed_tools
    refute :messages in proof.child_input_keys
    refute :transcript in proof.child_input_keys
  end

  test "Stage 1 requires an explicit read path" do
    assert_raise KeyError, fn ->
      ChildRunDispatcher.execute_stage1(parent_context())
    end
  end

  test "Runner proof gate requires an explicit read path" do
    assert_raise KeyError, fn ->
      ChildRunDispatcher.execute_runner_proof_gate(parent_context())
    end
  end

  test "Runner proof gate blocks missing reserve budget telemetry" do
    assert {:error, proof} =
             ChildRunDispatcher.execute_runner_proof_gate(parent_context(),
               read_path: @synthetic_path
             )

    assert proof.status == :budget_denied
    assert proof.stage == :runner_control_flow_proof
    assert proof.denial_reason == :missing_remaining_warn_fuse_budget
    assert proof.terminal_blocker
    refute proof.spawn_real_child
  end

  test "Runner proof gate blocks nil non-integer negative or unlabeled reserve budget telemetry" do
    cases = [
      {[remaining_warn_fuse_budget: nil, budget_source: :synthetic_fixture], :nil_remaining_warn_fuse_budget},
      {[remaining_warn_fuse_budget: "unknown", budget_source: :synthetic_fixture], :invalid_remaining_warn_fuse_budget},
      {[remaining_warn_fuse_budget: -1, budget_source: :synthetic_fixture], :negative_remaining_warn_fuse_budget},
      {[remaining_warn_fuse_budget: 520_000], :missing_or_invalid_budget_source},
      {[remaining_warn_fuse_budget: 520_000, budget_source: :defaulted], :missing_or_invalid_budget_source}
    ]

    for {opts, reason} <- cases do
      assert {:error, proof} =
               ChildRunDispatcher.execute_runner_proof_gate(parent_context(), [read_path: @synthetic_path] ++ opts)

      assert proof.status == :budget_denied
      assert proof.denial_reason == reason
      assert proof.terminal_blocker
      refute proof.spawn_real_child
    end
  end

  test "Runner proof gate accepts explicitly labeled synthetic budget fixture" do
    assert {:ok, proof} =
             ChildRunDispatcher.execute_runner_proof_gate(
               parent_context(),
               [read_path: @synthetic_path] ++ runner_budget_opts()
             )

    assert proof.status == :readonly_allowed
    assert proof.stage == :runner_control_flow_proof
    assert proof.budget_source == :synthetic_fixture
    assert proof.remaining_warn_fuse_budget == 520_000
    refute proof.terminal_blocker
    refute proof.spawn_real_child
  end

  test "Stage 1 denies paths outside the filtered child input contract" do
    assert {:error, proof} =
             ChildRunDispatcher.execute_stage1(parent_context(),
               read_path: "synthetic://dts39/not-listed.md",
               requested_tool: :read_file
             )

    assert proof.status == :path_denied
    assert proof.denial_reason == :path_not_in_child_read_targets
    refute proof.spawn_real_child

    path_check = Enum.find(proof.trace, &(&1.event == :path_check))
    refute path_check.attrs.allowed
  end

  test "write, shell, git, Linear, browser, and nested-agent tools are denied" do
    denied_tools = [
      :write_file,
      :shell,
      :apply_patch,
      :git_commit,
      :linear_status,
      :browser_click,
      :spawn_agent
    ]

    for denied_tool <- denied_tools do
      assert {:error, proof} =
               ChildRunDispatcher.execute_stage1(parent_context(),
                 read_path: @synthetic_path,
                 requested_tool: denied_tool,
                 requested_tools: [:read_file, denied_tool]
               )

      assert proof.status == :tool_denied
      assert proof.denial_reason == :tool_not_in_effective_read_only_grant
      assert denied_tool in proof.effective_tool_grant.denied_tools
      refute proof.spawn_real_child

      path_check = Enum.find(proof.trace, &(&1.event == :path_check))
      assert path_check.attrs.allowed
    end
  end

  test "Stage 2 real read-only proof requires a passed Stage 1 synthetic/local proof" do
    with_real_read_fixture(fn real_read_path ->
      assert {:error, proof} =
               ChildRunDispatcher.execute_stage2_readonly(parent_context(real_read_path),
                 read_path: real_read_path,
                 requested_tool: :read_file
               )

      assert proof.status == :stage1_required
      assert proof.reason == :stage1_synthetic_local_pass_required
      refute proof.capability_enabled
      refute proof.spawn_real_child
    end)
  end

  test "Stage 2 requires an explicit read path" do
    assert_raise KeyError, fn ->
      ChildRunDispatcher.execute_stage2_readonly(parent_context())
    end
  end

  test "Stage 2 real read-only proof uses named path existence after Stage 1 passes" do
    with_real_read_fixture(fn real_read_path ->
      assert File.exists?(real_read_path)

      assert {:ok, stage1_proof} =
               ChildRunDispatcher.execute_stage1(parent_context(real_read_path),
                 read_path: real_read_path,
                 requested_tool: :read_file
               )

      assert {:ok, proof} =
               ChildRunDispatcher.execute_stage2_readonly(parent_context(real_read_path),
                 read_path: real_read_path,
                 requested_tool: :read_file,
                 stage1_proof: stage1_proof
               )

      assert proof.status == :readonly_allowed
      assert proof.stage == :real_readonly_path
      assert proof.read_path == real_read_path
      refute proof.capability_enabled
      refute proof.spawn_real_child
    end)
  end

  test "out-of-scope real read target is denied" do
    with_real_read_fixture(fn real_read_path ->
      assert {:ok, stage1_proof} =
               ChildRunDispatcher.execute_stage1(parent_context(real_read_path),
                 read_path: real_read_path,
                 requested_tool: :read_file
               )

      assert {:error, proof} =
               ChildRunDispatcher.execute_stage2_readonly(parent_context(real_read_path),
                 read_path: "C:\\unauthorized\\target.txt",
                 requested_tool: :read_file,
                 stage1_proof: stage1_proof
               )

      assert proof.status == :path_denied
      assert proof.denial_reason == :path_not_in_allowed_real_read_targets

      path_check = Enum.find(proof.trace, &(&1.event == :path_check))
      refute path_check.attrs.allowed
    end)
  end

  test "stale parent revision is rejected before child result synthesis" do
    assert {:error, proof} =
             ChildRunDispatcher.reject_stale_parent(parent_context(), "r2")

    assert proof.status == :stale_rejected
    assert proof.reason == :parent_revision_changed
    assert [%{event: :stale_rejection}] = proof.trace
  end

  test "fresh parent revision is accepted and STOP closes with watchdog ledger" do
    assert {:ok, proof} =
             ChildRunDispatcher.reject_stale_parent(parent_context(), "r1")

    assert proof.status == :fresh_parent_revision

    stop_event = ChildRunDispatcher.close_at_stop(proof.contract)
    assert stop_event.event == :stop_close
    assert stop_event.attrs.issue_identifier == "DTS-39"
    assert stop_event.attrs.ledger_closed_by == :watchdog
  end
end
