defmodule SymphonyElixir.ChildRunDispatcher do
  @moduledoc """
  Disabled/proof-only dispatcher skeleton for DTS-39.

  It proves contract mechanics and trace output. It does not spawn agents, grant
  runtime capability, mutate files, or enter the live runner dispatch path.
  """

  alias SymphonyElixir.ChildRunContract
  alias SymphonyElixir.ChildRunTrace

  @spec prepare(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(parent_context, opts \\ []) when is_map(parent_context) do
    with {:ok, contract} <- ChildRunContract.build(parent_context, opts) do
      {:ok,
       %{
         status: :prepared_proof_only,
         contract: contract,
         child_input: contract.child_input,
         effective_tool_grant: contract.effective_tool_grant,
         memory_policy: contract.memory_policy,
         spawn_real_child: false
       }}
    end
  end

  @spec execute_stage1(map(), keyword()) :: {:ok, map()} | {:error, map()} | {:error, term()}
  def execute_stage1(parent_context, opts \\ []) when is_map(parent_context) do
    requested_tool = Keyword.get(opts, :requested_tool, :read_file)
    read_path = Keyword.fetch!(opts, :read_path)

    with {:ok, prepared} <- prepare(parent_context, opts) do
      evaluate_readonly_attempt(prepared.contract, requested_tool, read_path, :synthetic_local)
    end
  end

  @spec execute_stage2_readonly(map(), keyword()) :: {:ok, map()} | {:error, map()} | {:error, term()}
  def execute_stage2_readonly(parent_context, opts \\ []) when is_map(parent_context) do
    requested_tool = Keyword.get(opts, :requested_tool, :read_file)
    read_path = Keyword.fetch!(opts, :read_path)

    with :ok <- validate_stage1_proof(Keyword.get(opts, :stage1_proof)),
         {:ok, prepared} <- prepare(parent_context, opts) do
      if ChildRunContract.stage2_read_target_available?(prepared.contract, read_path) do
        evaluate_readonly_attempt(prepared.contract, requested_tool, read_path, :real_readonly_path)
      else
        contract = prepared.contract
        stage = :real_readonly_path
        reason = :path_not_in_allowed_real_read_targets

        {:error, denied_proof(:path_denied, contract, requested_tool, read_path, stage, reason)}
      end
    end
  end

  @spec reject_stale_parent(map(), term(), keyword()) :: {:ok, map()} | {:error, map()} | {:error, term()}
  def reject_stale_parent(parent_context, expected_revision, opts \\ []) do
    with {:ok, prepared} <- prepare(parent_context, opts) do
      if ChildRunContract.stale_parent_revision?(prepared.contract, expected_revision) do
        {:error,
         %{
           status: :stale_rejected,
           reason: :parent_revision_changed,
           trace: [
             ChildRunTrace.event(:stale_rejection, %{
               expected_revision: expected_revision,
               actual_revision: prepared.contract.child_input.parent_revision
             })
           ]
         }}
      else
        {:ok, %{status: :fresh_parent_revision, contract: prepared.contract}}
      end
    end
  end

  @spec close_at_stop(map()) :: map()
  def close_at_stop(contract) when is_map(contract) do
    ChildRunTrace.event(:stop_close, %{
      issue_identifier: contract.child_input.issue_identifier,
      ledger_closed_by: :watchdog,
      state: :closed_at_stop_timestamp
    })
  end

  defp evaluate_readonly_attempt(contract, requested_tool, read_path, stage) do
    cond do
      not ChildRunContract.path_allowed?(contract, read_path) ->
        reason = :path_not_in_child_read_targets
        {:error, denied_proof(:path_denied, contract, requested_tool, read_path, stage, reason)}

      not ChildRunContract.tool_allowed?(contract, requested_tool) ->
        reason = :tool_not_in_effective_read_only_grant
        {:error, denied_proof(:tool_denied, contract, requested_tool, read_path, stage, reason)}

      true ->
        {:ok, proof(:readonly_allowed, contract, requested_tool, read_path, stage)}
    end
  end

  defp proof(status, contract, requested_tool, read_path, stage, opts \\ []) do
    denied? = status in [:path_denied, :tool_denied]
    denial_reason = Keyword.get(opts, :denial_reason)

    trace =
      if denied? do
        path_allowed = ChildRunContract.path_allowed?(contract, read_path)
        ChildRunTrace.denial_ledger(contract, requested_tool, read_path, path_allowed: path_allowed)
      else
        ChildRunTrace.valid_run_ledger(contract, read_path)
      end

    %{
      status: status,
      stage: stage,
      proof_only: true,
      capability_enabled: false,
      spawn_real_child: false,
      requested_tool: requested_tool,
      read_path: read_path,
      denial_reason: denial_reason,
      child_input_keys: Map.keys(contract.child_input) |> Enum.sort(),
      effective_tool_grant: contract.effective_tool_grant,
      memory_policy: contract.memory_policy,
      trace: trace,
      parent_owns_synthesis: true
    }
  end

  defp denied_proof(status, contract, requested_tool, read_path, stage, reason) do
    proof(status, contract, requested_tool, read_path, stage, denial_reason: reason)
  end

  defp validate_stage1_proof(%{
         status: :readonly_allowed,
         stage: :synthetic_local,
         proof_only: true,
         spawn_real_child: false
       }),
       do: :ok

  defp validate_stage1_proof(_stage1_proof) do
    {:error,
     %{
       status: :stage1_required,
       reason: :stage1_synthetic_local_pass_required,
       proof_only: true,
       capability_enabled: false,
       spawn_real_child: false
     }}
  end
end
