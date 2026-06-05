defmodule SymphonyElixir.ChildRunContract do
  @moduledoc """
  Proof-only contract for read-only child-run slices.

  This module models the runner control-plane contract without enabling
  write-capable subagent-fork, spawning a child process, or live child dispatch.
  """

  @read_only_tools [:read_file, :list_dir, :search_text]
  @denied_tool_classes %{
    write: [:write_file, :delete_file, :apply_patch],
    shell: [:shell, :exec, :run_command],
    git_mutation: [:git_commit, :git_push, :git_checkout, :git_reset],
    linear_mutation: [:linear_comment, :linear_status, :linear_relationship],
    browser_action: [:browser_click, :browser_type, :browser_navigate],
    nested_agent: [:spawn_agent, :wait_agent, :send_input, :resume_agent, :close_agent]
  }
  @known_tool_lookup Map.new(
                       @read_only_tools ++
                         (@denied_tool_classes |> Map.values() |> List.flatten()) ++
                         [:unknown_tool],
                       &{Atom.to_string(&1), &1}
                     )
  @blocked_parent_keys [
    :messages,
    :conversation,
    :parent_history,
    :raw_transcript,
    :transcript,
    "messages",
    "conversation",
    "parent_history",
    "raw_transcript",
    "transcript"
  ]
  @allowed_child_input_keys [
    :issue_identifier,
    :goal,
    :bounded_question,
    :read_targets,
    :source_refs,
    :constraints,
    :parent_revision
  ]
  @allowed_child_input_key_lookup Map.new(@allowed_child_input_keys, &{Atom.to_string(&1), &1})

  @spec read_only_tools() :: [atom()]
  def read_only_tools, do: @read_only_tools

  @spec denied_tool_classes() :: %{atom() => [atom()]}
  def denied_tool_classes, do: @denied_tool_classes

  @spec memory_policy() :: map()
  def memory_policy do
    %{
      persistent_child_memory: false,
      child_memory_destination: :none,
      transcript_destination: :protected_diagnostics,
      transcript_evidence_allowed: false
    }
  end

  @spec default_budget_policy() :: map()
  def default_budget_policy do
    %{
      child_token_budget: 120_000,
      child_output_cap_tokens: 1_500,
      total_child_pool_max_tokens: 600_000,
      parent_synthesis_reserve_tokens: 400_000,
      budget_warning_ratio: 0.8
    }
  end

  @spec build(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def build(parent_context, opts \\ []) when is_map(parent_context) do
    requested_tools = Keyword.get(opts, :requested_tools, @read_only_tools)
    budget_policy = Keyword.get(opts, :budget_policy, default_budget_policy())
    child_input = filter_child_input(parent_context)
    tool_grant = effective_tool_grant(requested_tools)

    with :ok <- validate_budget_policy(budget_policy),
         :ok <- validate_required_child_fields(child_input) do
      {:ok,
       %{
         contract_version: "dts39-proof-only-v1",
         proof_only: true,
         capability_id: :subagent_fork_readonly_proof_only,
         capability_enabled: false,
         spawn_real_child: false,
         child_input: child_input,
         effective_tool_grant: tool_grant,
         memory_policy: memory_policy(),
         budget_policy: budget_policy
       }}
    end
  end

  @spec filter_child_input(map()) :: map()
  def filter_child_input(parent_context) when is_map(parent_context) do
    parent_context
    |> Map.drop(@blocked_parent_keys)
    |> Enum.reduce(%{}, fn {key, value}, child_input ->
      case normalize_child_input_key(key) do
        key when key in @allowed_child_input_keys -> Map.put(child_input, key, value)
        _ -> child_input
      end
    end)
    |> normalize_read_targets()
  end

  @spec effective_tool_grant([atom() | String.t()]) :: map()
  def effective_tool_grant(requested_tools) when is_list(requested_tools) do
    requested = Enum.map(requested_tools, &normalize_tool/1)

    allowed =
      requested
      |> Enum.filter(&(&1 in @read_only_tools))
      |> Enum.uniq()

    denied =
      requested
      |> Enum.reject(&(&1 in @read_only_tools))
      |> Enum.uniq()

    %{
      allowed_tools: allowed,
      denied_tools: denied,
      denied_tool_classes: denied_tool_classes_for(denied),
      read_only_only: denied == [],
      no_write_or_side_effect_tools: denied == []
    }
  end

  @spec tool_allowed?(map(), atom() | String.t()) :: boolean()
  def tool_allowed?(contract, requested_tool) do
    requested = normalize_tool(requested_tool)
    requested in get_in(contract, [:effective_tool_grant, :allowed_tools])
  end

  @spec path_allowed?(map(), String.t()) :: boolean()
  def path_allowed?(contract, path) when is_binary(path) do
    contract
    |> get_in([:child_input, :read_targets])
    |> List.wrap()
    |> Enum.any?(&same_path?(&1, path))
  end

  @spec stage2_read_target_available?(map(), String.t()) :: boolean()
  def stage2_read_target_available?(contract, path) when is_binary(path) do
    path_allowed?(contract, path) and File.exists?(path)
  end

  @spec budget_threshold_state(map(), non_neg_integer()) :: :ok | :warning | :hard_cap
  def budget_threshold_state(contract, used_tokens) when is_integer(used_tokens) and used_tokens >= 0 do
    policy = contract.budget_policy
    child_budget = policy.child_token_budget
    warning_at = trunc(child_budget * policy.budget_warning_ratio)

    cond do
      used_tokens >= child_budget -> :hard_cap
      used_tokens >= warning_at -> :warning
      true -> :ok
    end
  end

  @spec parent_reserve_preserved?(map(), integer()) :: boolean()
  def parent_reserve_preserved?(contract, remaining_warn_fuse_budget) when is_integer(remaining_warn_fuse_budget) do
    policy = contract.budget_policy

    remaining_warn_fuse_budget - policy.child_token_budget >=
      policy.parent_synthesis_reserve_tokens
  end

  @spec stale_parent_revision?(map(), term()) :: boolean()
  def stale_parent_revision?(contract, expected_revision) do
    contract
    |> get_in([:child_input, :parent_revision])
    |> then(&(&1 != nil and &1 != expected_revision))
  end

  defp validate_required_child_fields(child_input) do
    missing =
      [:issue_identifier, :bounded_question, :read_targets]
      |> Enum.reject(&(Map.get(child_input, &1) not in [nil, [], ""]))

    case missing do
      [] -> :ok
      _ -> {:error, {:missing_child_input_fields, missing}}
    end
  end

  defp validate_budget_policy(policy) do
    cond do
      policy.child_output_cap_tokens > 1_500 ->
        {:error, {:child_output_cap_too_high, policy.child_output_cap_tokens}}

      policy.child_token_budget > policy.total_child_pool_max_tokens ->
        {:error, {:child_budget_exceeds_pool, policy.child_token_budget}}

      policy.parent_synthesis_reserve_tokens < 400_000 ->
        {:error, {:parent_synthesis_reserve_too_low, policy.parent_synthesis_reserve_tokens}}

      true ->
        :ok
    end
  end

  defp normalize_read_targets(child_input) do
    Map.update(child_input, :read_targets, [], &List.wrap/1)
  end

  defp normalize_child_input_key(key) when is_atom(key), do: key

  defp normalize_child_input_key(key) when is_binary(key) do
    Map.get(@allowed_child_input_key_lookup, key, key)
  end

  defp normalize_tool(tool) when is_atom(tool), do: tool

  defp normalize_tool(tool) when is_binary(tool) do
    normalized =
      tool
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    Map.get(@known_tool_lookup, normalized, :unknown_tool)
  end

  defp denied_tool_classes_for(denied_tools) do
    Enum.reduce(@denied_tool_classes, [], fn {class, tools}, classes ->
      if Enum.any?(tools, &(&1 in denied_tools)), do: [class | classes], else: classes
    end)
    |> Enum.reverse()
  end

  defp same_path?(left, right) do
    normalize_path(left) == normalize_path(right)
  end

  defp normalize_path(path) do
    path
    |> to_string()
    |> String.replace("\\", "/")
    |> String.downcase()
  end
end
