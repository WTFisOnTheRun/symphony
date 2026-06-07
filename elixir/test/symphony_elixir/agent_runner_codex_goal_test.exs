defmodule SymphonyElixir.AgentRunnerCodexGoalTest do
  use SymphonyElixir.TestSupport

  defp issue(description) do
    %Issue{
      id: "issue-dts-48",
      identifier: "DTS-48",
      title: "Add proof-only Codex Goal bridge for Symphony Runner",
      description: description,
      state: "In Progress"
    }
  end

  test "codex thread goal contract parser accepts explicit objective and token budget" do
    description = """
    ## Goal

    Keep the parent Runner oriented.

    ## Required Capabilities

    - `codex-thread-goal-bridge`: set the parent Codex thread goal.

    ## Codex Thread Goal

    objective: Keep the DTS-48 Codex session focused on proof-only goal bridge work.
    token_budget: 120000
    """

    assert {:ok, goal_contract} = AgentRunner.codex_thread_goal_contract_for_test(issue(description))
    assert goal_contract.objective == "Keep the DTS-48 Codex session focused on proof-only goal bridge work."
    assert goal_contract.token_budget == 120_000
  end

  test "issues without a Codex Thread Goal contract preserve existing no-goal behavior" do
    assert {:ok, :not_requested} =
             AgentRunner.codex_thread_goal_contract_for_test(issue("## Goal\n\nRun the normal ticket workflow."))
  end

  test "Codex Thread Goal sections require an explicit capability request" do
    description = """
    ## Goal

    Keep the parent Runner oriented.

    ## Codex Thread Goal

    objective: Keep the DTS-48 Codex session focused.
    """

    assert {:error, {:missing_codex_thread_goal_capability_request, "codex-thread-goal-bridge"}} =
             AgentRunner.codex_thread_goal_contract_for_test(issue(description))
  end

  test "malformed Codex Thread Goal contracts fail closed before app-server launch" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-agent-runner-codex-goal-malformed-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-goal-malformed.trace")

      File.mkdir_p!(test_root)

      File.write!(codex_binary, """
      #!/bin/sh
      printf 'RUN\\n' >> "#{bash_command_path(trace_file)}"
      exit 42
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{bash_command_path(codex_binary)} app-server"
      )

      description = """
      ## Goal

      Demonstrate malformed Codex Thread Goal handling.

      ## Required Capabilities

      - codex-thread-goal-bridge: set the parent Codex thread goal.

      ## Codex Thread Goal

      token_budget: eventually
      """

      assert {:error, {:missing_codex_thread_goal_field, "objective"}} =
               AgentRunner.codex_thread_goal_contract_for_test(issue(description))

      assert_raise RuntimeError, ~r/codex_thread_goal_contract_invalid/, fn ->
        AgentRunner.run(issue(description), nil, issue_state_fetcher: fn _ -> {:ok, []} end, max_turns: 1)
      end

      refute File.exists?(trace_file)
    after
      File.rm_rf(test_root)
    end
  end

  test "runner sets Codex thread goal after session start and before first turn" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-agent-runner-codex-goal-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-goal.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(test_root)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-goal.trace}"

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-dts-48"}}}'
            ;;
          *'"method":"thread/goal/set"'*)
            printf '%s\\n' '{"id":4,"result":{"goal":{"threadId":"thread-dts-48","objective":"Keep DTS-48 focused on the Codex Goal bridge only.","status":"active","tokenBudget":120000,"tokensUsed":0,"timeUsedSeconds":0,"createdAt":1,"updatedAt":1}}}'
            ;;
          *'"method":"turn/start"'*)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-dts-48"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{bash_command_path(codex_binary)} app-server"
      )

      description = """
      ## Goal

      Add a proof-only Codex Goal bridge.

      ## Required Capabilities

      - codex-thread-goal-bridge: set the parent Codex thread goal.

      ## Codex Thread Goal

      objective: Keep DTS-48 focused on the Codex Goal bridge only.
      token_budget: 120000
      """

      assert :ok =
               AgentRunner.run(issue(description), self(),
                 issue_state_fetcher: fn _ -> {:ok, []} end,
                 max_turns: 1
               )

      assert_receive {:codex_worker_update, "issue-dts-48", %{event: :codex_thread_goal_set, goal: goal}}, 500
      assert goal["threadId"] == "thread-dts-48"
      assert goal["objective"] == "Keep DTS-48 focused on the Codex Goal bridge only."

      payloads =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(fn line -> line |> String.trim_leading("JSON:") |> Jason.decode!() end)

      methods = Enum.map(payloads, & &1["method"])
      goal_set_index = Enum.find_index(methods, &(&1 == "thread/goal/set"))
      turn_start_index = Enum.find_index(methods, &(&1 == "turn/start"))

      assert is_integer(goal_set_index)
      assert is_integer(turn_start_index)
      assert goal_set_index < turn_start_index

      goal_set_payload = Enum.at(payloads, goal_set_index)
      assert get_in(goal_set_payload, ["params", "threadId"]) == "thread-dts-48"
      assert get_in(goal_set_payload, ["params", "objective"]) == "Keep DTS-48 focused on the Codex Goal bridge only."
      assert get_in(goal_set_payload, ["params", "tokenBudget"]) == 120_000
    after
      File.rm_rf(test_root)
    end
  end
end
