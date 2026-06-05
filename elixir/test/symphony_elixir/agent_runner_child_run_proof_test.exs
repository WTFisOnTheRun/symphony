defmodule SymphonyElixir.AgentRunnerChildRunProofTest do
  use SymphonyElixir.TestSupport

  @valid_description """
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
    assert proof.parent_owns_synthesis
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
    assert prompt =~ "- parent_owns_synthesis: true"
    assert prompt =~ "parent Runner remains the only writer"
  end

  test "bare subagent-fork capability request is rejected before proof execution" do
    description = """
    ## Goal

    Use child execution.

    ## Required Capabilities

    - subagent-fork
    """

    assert {:error, proof} = AgentRunner.child_run_dispatcher_proof_for_test(issue(description))

    assert proof.status == :capability_denied
    assert proof.stage == :runner_control_flow_proof
    assert proof.denial_reason == :bare_subagent_fork_request
    refute proof.capability_enabled
    refute proof.spawn_real_child
  end

  test "first-turn prompt includes rejected Dispatcher proof decisions" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-agent-runner-child-proof-rejected-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    description = """
    ## Required Capabilities

    - subagent-fork
    """

    prompt = AgentRunner.build_turn_prompt_for_test(workspace, issue(description))

    assert prompt =~ "## Runner Child-Run Dispatcher Proof Gate"
    assert prompt =~ "- decision: rejected"
    assert prompt =~ "- status: capability_denied"
    assert prompt =~ "- denial_reason: bare_subagent_fork_request"
    assert prompt =~ "- spawn_real_child: false"
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

        Requested child tools: read_file, write_file, shell, apply_patch, git_commit, linear_status, browser_click, spawn_agent
        """

    assert {:error, proof} = AgentRunner.child_run_dispatcher_proof_for_test(issue(description))

    assert proof.status == :tool_denied
    assert proof.denial_reason == :requested_tool_grant_not_read_only
    refute proof.spawn_real_child

    assert MapSet.new(proof.effective_tool_grant.denied_tool_classes) ==
             MapSet.new([
               :write,
               :shell,
               :git_mutation,
               :linear_mutation,
               :browser_action,
               :nested_agent
             ])

    assert :write_file in proof.effective_tool_grant.denied_tools
    assert :shell in proof.effective_tool_grant.denied_tools
    assert :apply_patch in proof.effective_tool_grant.denied_tools
    assert :git_commit in proof.effective_tool_grant.denied_tools
    assert :linear_status in proof.effective_tool_grant.denied_tools
    assert :browser_click in proof.effective_tool_grant.denied_tools
    assert :spawn_agent in proof.effective_tool_grant.denied_tools
  end

  test "parent reserve breach is rejected before Dispatcher proof execution" do
    description =
      @valid_description <>
        """

        remaining_warn_fuse_budget: 500000
        """

    assert {:error, proof} = AgentRunner.child_run_dispatcher_proof_for_test(issue(description))

    assert proof.status == :budget_denied
    assert proof.denial_reason == :parent_synthesis_reserve_breach
    refute proof.spawn_real_child

    budget_event = Enum.find(proof.trace, &(&1.event == :budget_threshold))
    assert budget_event.attrs.state == :hard_cap
    assert budget_event.attrs.reason == :parent_synthesis_reserve_breach
  end

  test "unrelated issues do not enter the child-run proof gate" do
    assert :not_requested =
             AgentRunner.child_run_dispatcher_proof_for_test(issue("Regular ticket without a child-run proof request."))
  end
end
