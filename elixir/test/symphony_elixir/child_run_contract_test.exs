defmodule SymphonyElixir.ChildRunContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ChildRunContract

  @parent_context %{
    issue_identifier: "DTS-39",
    goal: "proof-only read-only child-run slice",
    bounded_question: "Which named references should a child inspect?",
    read_targets: ["synthetic://dts39/context.md"],
    source_refs: ["R4 plan", "DTS 21 sequencing log"],
    constraints: ["no write tools", "no runtime capability flip"],
    parent_revision: "parent-r1",
    messages: ["full parent history must not be inherited"],
    parent_history: "blocked",
    raw_transcript: "protected diagnostic",
    unrelated_context: "not passed to child"
  }

  test "filters child input and excludes parent history or transcripts" do
    {:ok, contract} = ChildRunContract.build(@parent_context)

    assert contract.proof_only
    refute contract.capability_enabled
    refute contract.spawn_real_child

    assert Map.keys(contract.child_input) |> Enum.sort() ==
             [
               :bounded_question,
               :constraints,
               :goal,
               :issue_identifier,
               :parent_revision,
               :read_targets,
               :source_refs
             ]

    refute Map.has_key?(contract.child_input, :messages)
    refute Map.has_key?(contract.child_input, :parent_history)
    refute Map.has_key?(contract.child_input, :raw_transcript)
    refute Map.has_key?(contract.child_input, :unrelated_context)
  end

  test "normalizes string-keyed child input from decoded payloads" do
    parent_context =
      @parent_context
      |> Enum.map(fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.new()

    {:ok, contract} = ChildRunContract.build(parent_context)

    assert contract.child_input.issue_identifier == "DTS-39"
    assert contract.child_input.bounded_question == "Which named references should a child inspect?"
    assert contract.child_input.read_targets == ["synthetic://dts39/context.md"]
    refute Map.has_key?(contract.child_input, "messages")
    refute Map.has_key?(contract.child_input, "raw_transcript")
  end

  test "effective tool grant allows read-only tools and denies side-effect classes" do
    {:ok, contract} =
      ChildRunContract.build(@parent_context,
        requested_tools: [
          :read_file,
          :list_dir,
          :search_text,
          :write_file,
          :shell,
          :apply_patch,
          :git_commit,
          :linear_status,
          :browser_click,
          :spawn_agent
        ]
      )

    grant = contract.effective_tool_grant

    assert grant.allowed_tools == [:read_file, :list_dir, :search_text]
    assert :write_file in grant.denied_tools
    assert :shell in grant.denied_tools
    assert :apply_patch in grant.denied_tools
    assert :git_commit in grant.denied_tools
    assert :linear_status in grant.denied_tools
    assert :browser_click in grant.denied_tools
    assert :spawn_agent in grant.denied_tools

    assert MapSet.new(grant.denied_tool_classes) ==
             MapSet.new([
               :write,
               :shell,
               :git_mutation,
               :linear_mutation,
               :browser_action,
               :nested_agent
             ])

    refute grant.no_write_or_side_effect_tools
  end

  test "default effective tool grant is read-only only" do
    {:ok, contract} = ChildRunContract.build(@parent_context)

    assert ChildRunContract.read_only_tools() == [:read_file, :list_dir, :search_text]
    assert contract.effective_tool_grant.allowed_tools == [:read_file, :list_dir, :search_text]
    assert contract.effective_tool_grant.denied_tools == []
    assert contract.effective_tool_grant.denied_tool_classes == []
    assert contract.effective_tool_grant.read_only_only
    assert contract.effective_tool_grant.no_write_or_side_effect_tools
  end

  test "denied tool classes document every side-effect lane" do
    assert ChildRunContract.denied_tool_classes() == %{
             write: [:write_file, :delete_file, :apply_patch],
             shell: [:shell, :exec, :run_command],
             git_mutation: [:git_commit, :git_push, :git_checkout, :git_reset],
             linear_mutation: [:linear_comment, :linear_status, :linear_relationship],
             browser_action: [:browser_click, :browser_type, :browser_navigate],
             nested_agent: [:spawn_agent, :wait_agent, :send_input, :resume_agent, :close_agent, :subagent_fork]
           }
  end

  test "binary tool names normalize without creating arbitrary atoms" do
    {:ok, contract} =
      ChildRunContract.build(@parent_context,
        requested_tools: ["read-file", "write-file", "unknown-danger", "*", "subagent-fork"]
      )

    assert contract.effective_tool_grant.allowed_tools == [:read_file]
    assert :write_file in contract.effective_tool_grant.denied_tools
    assert :unknown_tool in contract.effective_tool_grant.denied_tools
    assert :all_tools in contract.effective_tool_grant.denied_tools
    assert :subagent_fork in contract.effective_tool_grant.denied_tools
    assert :nested_agent in contract.effective_tool_grant.denied_tool_classes
  end

  test "atom and non-string tool declarations normalize through the same grant policy" do
    {:ok, contract} =
      ChildRunContract.build(@parent_context,
        requested_tools: [:read_file, :shell, 123]
      )

    assert contract.effective_tool_grant.allowed_tools == [:read_file]
    assert :shell in contract.effective_tool_grant.denied_tools
    assert :unknown_tool in contract.effective_tool_grant.denied_tools
  end

  test "structured context tool declarations normalize atom and non-string values" do
    parent_context =
      Map.merge(@parent_context, %{
        allowed_child_tools: :read_file,
        effective_tool_grant: %{
          denied_tools: 123
        }
      })

    {:ok, contract} = ChildRunContract.build(parent_context)

    assert contract.effective_tool_grant.allowed_tools == [:read_file]
    assert :unknown_tool in contract.effective_tool_grant.denied_tools
  end

  test "parses structured allowed_child_tools and effective grant ledger fields" do
    parent_context =
      Map.merge(@parent_context, %{
        "allowed_child_tools" => "read_file, list_dir, write_file",
        "effective_tool_grant" => %{
          "allowed_tools" => ["search_text"],
          "denied_tools" => ["shell", "unknown_danger"]
        }
      })

    {:ok, contract} = ChildRunContract.build(parent_context)

    assert contract.effective_tool_grant.allowed_tools == [:read_file, :list_dir, :search_text]
    assert :write_file in contract.effective_tool_grant.denied_tools
    assert :shell in contract.effective_tool_grant.denied_tools
    assert :unknown_tool in contract.effective_tool_grant.denied_tools
  end

  test "memory and transcript policy is diagnostic-only and not persistent evidence" do
    assert ChildRunContract.memory_policy() == %{
             persistent_child_memory: false,
             child_memory_destination: :none,
             transcript_destination: :protected_diagnostics,
             transcript_evidence_allowed: false
           }
  end

  test "budget policy preserves child output cap and parent synthesis reserve" do
    {:ok, contract} = ChildRunContract.build(@parent_context)

    assert contract.budget_policy.child_output_cap_tokens == 1_500
    assert contract.budget_policy.parent_synthesis_reserve_tokens == 400_000
    assert ChildRunContract.path_allowed?(contract, "SYNTHETIC://DTS39\\CONTEXT.MD")
    refute ChildRunContract.path_allowed?(contract, "synthetic://dts39/other.md")
    refute ChildRunContract.stage2_read_target_available?(contract, "synthetic://dts39/context.md")
    refute ChildRunContract.stale_parent_revision?(contract, "parent-r1")
    assert ChildRunContract.stale_parent_revision?(contract, "parent-r2")
    assert ChildRunContract.budget_threshold_state(contract, 95_999) == :ok
    assert ChildRunContract.budget_threshold_state(contract, 96_000) == :warning
    assert ChildRunContract.budget_threshold_state(contract, 120_000) == :hard_cap
    assert ChildRunContract.parent_reserve_preserved?(contract, 520_000)
    refute ChildRunContract.parent_reserve_preserved?(contract, 500_000)
  end

  test "over-cap child output budget is rejected before proof execution" do
    assert {:error, {:child_output_cap_too_high, 1_501}} =
             ChildRunContract.build(@parent_context,
               budget_policy: %{
                 ChildRunContract.default_budget_policy()
                 | child_output_cap_tokens: 1_501
               }
             )
  end

  test "invalid budget pool and parent reserve are rejected before proof execution" do
    assert {:error, {:child_budget_exceeds_pool, 120_000}} =
             ChildRunContract.build(@parent_context,
               budget_policy: %{
                 ChildRunContract.default_budget_policy()
                 | total_child_pool_max_tokens: 100_000
               }
             )

    assert {:error, {:parent_synthesis_reserve_too_low, 399_999}} =
             ChildRunContract.build(@parent_context,
               budget_policy: %{
                 ChildRunContract.default_budget_policy()
                 | parent_synthesis_reserve_tokens: 399_999
               }
             )
  end

  test "required child input fields are enforced pre-spawn" do
    assert {:error, {:missing_child_input_fields, missing}} =
             ChildRunContract.build(%{
               issue_identifier: "DTS-39",
               read_targets: []
             })

    assert :bounded_question in missing
    assert :read_targets in missing
  end
end
