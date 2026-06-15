defmodule SymphonyElixir.AgentRunnerChildRunProofTest do
  use SymphonyElixir.TestSupport

  @valid_description """
  ## Goal

  Wire a read-only child-run Dispatcher proof gate into Runner control flow.
  The request is proof-only and must not spawn a real child agent.

  remaining_warn_fuse_budget: 520000
  budget_source: synthetic_fixture
  """

  @valid_description_without_budget """
  ## Goal

  Wire a read-only child-run Dispatcher proof gate into Runner control flow.
  The request is proof-only and must not spawn a real child agent.
  """

  defp issue(description) do
    %Issue{
      id: "issue-dts-40",
      identifier: "DTS-40",
      title: "DTS: Wire read-only child-run dispatcher proof path into Runner control flow",
      description: description,
      state: "Symphony Ready"
    }
  end

  test "first-turn prompt routes a valid read-only proof request through the Dispatcher gate" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-agent-runner-child-proof-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    assert {:ok, proof} = AgentRunner.child_run_dispatcher_proof_for_test(issue(@valid_description))
    assert proof.status == :readonly_allowed
    assert proof.stage == :runner_control_flow_proof
    assert proof.proof_only
    refute proof.capability_enabled
    refute proof.spawn_real_child
    refute proof.terminal_blocker
    assert proof.parent_owns_synthesis
    assert proof.budget_source == :synthetic_fixture
    assert proof.remaining_warn_fuse_budget == 520_000
    assert :read_file in proof.effective_tool_grant.allowed_tools

    refute :messages in proof.child_input_keys
    refute :parent_history in proof.child_input_keys
    refute :raw_transcript in proof.child_input_keys

    prompt = AgentRunner.build_turn_prompt_for_test(workspace, issue(@valid_description))

    assert prompt =~ "## Runner Child-Run Dispatcher Proof Gate"
    assert prompt =~ "- decision: accepted"
    assert prompt =~ "- status: readonly_allowed"
    assert prompt =~ "- stage: runner_control_flow_proof"
    assert prompt =~ "- capability_enabled: false"
    assert prompt =~ "- spawn_real_child: false"
    assert prompt =~ "- terminal_blocker: false"
    assert prompt =~ "- budget_source: synthetic_fixture"
    assert prompt =~ "- remaining_warn_fuse_budget: 520000"
    assert prompt =~ "- parent_owns_synthesis: true"
    assert prompt =~ "parent Runner remains the only writer"
  end

  test "missing Runner budget telemetry blocks instead of using a default reserve" do
    assert {:error, proof} = AgentRunner.child_run_dispatcher_proof_for_test(issue(@valid_description_without_budget))

    assert proof.status == :budget_denied
    assert proof.denial_reason == :missing_remaining_warn_fuse_budget
    assert proof.terminal_blocker
    assert proof.remaining_warn_fuse_budget == nil
    refute proof.spawn_real_child
  end

  test "bare subagent-fork capability request is rejected before proof execution" do
    description = """
    ## Goal

    Use child execution.

    remaining_warn_fuse_budget: 520000
    budget_source: synthetic_fixture

    ## Required Capabilities

    - subagent-fork
    """

    assert {:error, proof} = AgentRunner.child_run_dispatcher_proof_for_test(issue(description))

    assert proof.status == :capability_denied
    assert proof.stage == :runner_control_flow_proof
    assert proof.denial_reason == :bare_subagent_fork_request
    assert proof.terminal_blocker
    refute proof.capability_enabled
    refute proof.spawn_real_child
  end

  test "pre-turn gate makes rejected Dispatcher proof decisions terminal" do
    description = """
    ## Required Capabilities

    remaining_warn_fuse_budget: 520000
    budget_source: synthetic_fixture

    - subagent-fork
    """

    assert {:block, proof} = AgentRunner.child_run_pre_turn_gate_for_test(issue(description))

    assert proof.decision == :rejected
    assert proof.status == :capability_denied
    assert proof.denial_reason == :bare_subagent_fork_request
    assert proof.terminal_blocker
    refute proof.spawn_real_child
  end

  test "PromptBuilder renders rejected Dispatcher proof maps" do
    description = """
    ## Required Capabilities

    remaining_warn_fuse_budget: 520000
    budget_source: synthetic_fixture

    - subagent-fork
    """

    assert {:error, proof} = AgentRunner.child_run_dispatcher_proof_for_test(issue(description))

    block = PromptBuilder.child_run_dispatcher_proof_block({:error, proof})

    assert block =~ "- decision: rejected"
    assert block =~ "- status: capability_denied"
    assert block =~ "- terminal_blocker: true"
    assert block =~ "- budget_source: synthetic_fixture"
    assert block =~ "- remaining_warn_fuse_budget: 520000"
  end

  test "nested effective tool grant declarations reject denied child tools before turn launch" do
    description = """
    ## Required Capabilities

    remaining_warn_fuse_budget: 520000
    budget_source: synthetic_fixture

    effective_tool_grant:
      allowed_tools: read_file, list_dir
      denied_tools: shell
    """

    assert {:error, proof} = AgentRunner.child_run_dispatcher_proof_for_test(issue(description))
    assert proof.status == :tool_denied
    assert proof.denial_reason == :requested_tool_grant_not_read_only
    assert proof.terminal_blocker
    assert :shell in proof.effective_tool_grant.denied_tools
    refute proof.spawn_real_child
  end

  test "PromptBuilder renders generic Dispatcher proof errors" do
    block = PromptBuilder.child_run_dispatcher_proof_block({:error, :contract_failed})

    assert block =~ "## Runner Child-Run Dispatcher Proof Gate"
    assert block =~ "- decision: rejected"
    assert block =~ "- reason: :contract_failed"
    assert block =~ "- spawn_real_child: false"
  end

  test "write shell mutation browser and nested-agent tool grants are rejected before proof execution" do
    description =
      @valid_description <>
        """

        Requested child tools: read_file, write_file, shell, apply_patch, git_commit, linear_status, browser_click, salesforce_query, spawn_agent
        """

    assert {:error, proof} = AgentRunner.child_run_dispatcher_proof_for_test(issue(description))

    assert proof.status == :tool_denied
    assert proof.denial_reason == :requested_tool_grant_not_read_only
    assert proof.terminal_blocker
    refute proof.spawn_real_child

    assert MapSet.new(proof.effective_tool_grant.denied_tool_classes) ==
             MapSet.new([
               :write,
               :shell,
               :git_mutation,
               :linear_mutation,
               :browser_action,
               :business_system,
               :nested_agent
             ])

    assert :write_file in proof.effective_tool_grant.denied_tools
    assert :shell in proof.effective_tool_grant.denied_tools
    assert :apply_patch in proof.effective_tool_grant.denied_tools
    assert :git_commit in proof.effective_tool_grant.denied_tools
    assert :linear_status in proof.effective_tool_grant.denied_tools
    assert :browser_click in proof.effective_tool_grant.denied_tools
    assert :salesforce_query in proof.effective_tool_grant.denied_tools
    assert :spawn_agent in proof.effective_tool_grant.denied_tools
  end

  test "allowed_child_tools and effective grant fields are parsed and enforced" do
    description =
      @valid_description <>
        """

        allowed_child_tools: read_file, list_dir, shell
        effective_tool_grant.denied_tools: browser_click, unknown_tool_id
        """

    assert {:error, proof} = AgentRunner.child_run_dispatcher_proof_for_test(issue(description))

    assert proof.status == :tool_denied
    assert proof.denial_reason == :requested_tool_grant_not_read_only
    assert :shell in proof.effective_tool_grant.denied_tools
    assert :browser_click in proof.effective_tool_grant.denied_tools
    assert :unknown_tool in proof.effective_tool_grant.denied_tools
    assert proof.terminal_blocker
    refute proof.spawn_real_child
  end

  test "parent reserve breach is rejected before Dispatcher proof execution" do
    description =
      @valid_description_without_budget <>
        """

        remaining_warn_fuse_budget: 500000
        budget_source: synthetic_fixture
        """

    assert {:error, proof} = AgentRunner.child_run_dispatcher_proof_for_test(issue(description))

    assert proof.status == :budget_denied
    assert proof.denial_reason == :parent_synthesis_reserve_breach
    assert proof.terminal_blocker
    refute proof.spawn_real_child

    budget_event = Enum.find(proof.trace, &(&1.event == :budget_threshold))
    assert budget_event.attrs.state == :hard_cap
    assert budget_event.attrs.reason == :parent_synthesis_reserve_breach
  end

  test "unrelated issues do not enter the child-run proof gate" do
    assert :not_requested =
             AgentRunner.child_run_dispatcher_proof_for_test(issue("Regular ticket without a child-run proof request."))
  end

  test "terminal rejected proof blocks before Codex app-server turn launch" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-agent-runner-child-proof-terminal-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-trace.txt")

      File.mkdir_p!(test_root)

      File.write!(
        codex_binary,
        """
        #!/bin/sh
        printf 'RUN\\n' >> "#{bash_command_path(trace_file)}"
        exit 42
        """
      )

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{bash_command_path(codex_binary)} app-server"
      )

      description = """
      ## Required Capabilities

      remaining_warn_fuse_budget: 520000
      budget_source: synthetic_fixture

      - subagent-fork
      """

      assert_raise RuntimeError, ~r/child_run_dispatcher_pre_turn_blocked/, fn ->
        AgentRunner.run(issue(description))
      end

      refute File.exists?(trace_file)
    after
      File.rm_rf(test_root)
    end
  end
end
