defmodule SymphonyElixir.ChildRunReadOnlyAdapter do
  @moduledoc """
  DTS-41 read-only child adapter behind the hardened dispatcher gate.

  This module does not flip `subagent-fork`. It uses a bounded Codex app-server
  child thread/turn only after `ChildRunDispatcher` accepts the read-only request.
  """

  alias SymphonyElixir.ChildRunContract
  alias SymphonyElixir.ChildRunDispatcher
  alias SymphonyElixir.ChildRunTrace
  alias SymphonyElixir.Codex.AppServer

  @adapter_version "codex-app-server-readonly-child-thread-v0"

  @type run_result :: %{
          adapter_version: String.t(),
          status: :readonly_child_completed,
          decision: :accepted,
          stage: :real_readonly_child,
          proof_only: false,
          capability_enabled: false,
          spawn_real_child: true,
          child_session_id: String.t() | nil,
          child_thread_id: String.t() | nil,
          child_turn_id: String.t() | nil,
          read_path: String.t(),
          effective_tool_grant: map(),
          child_input_keys: [atom()],
          parent_owns_synthesis: true,
          dispatcher_proof: map(),
          trace: [map()]
        }

  @spec adapter_version() :: String.t()
  def adapter_version, do: @adapter_version

  @spec run(map(), map(), keyword()) :: {:ok, run_result()} | {:error, term()}
  def run(parent_context, issue, opts \\ []) when is_map(parent_context) and is_map(issue) do
    read_path = Keyword.fetch!(opts, :read_path)
    workspace = Keyword.fetch!(opts, :workspace)
    run_child = Keyword.get(opts, :run_child, &AppServer.run_readonly_child/4)

    with {:ok, dispatcher_proof} <- run_dispatcher_gate(parent_context, read_path, opts),
         {:ok, child_result} <-
           run_child.(workspace, child_prompt(parent_context, dispatcher_proof, read_path), issue, child_opts(opts)) do
      {:ok, completed_proof(parent_context, dispatcher_proof, child_result, read_path)}
    else
      {:error, %{terminal_blocker: _} = proof} ->
        {:error, {:dispatcher_gate_blocked, proof}}

      {:error, reason} ->
        {:error, {:readonly_child_failed, reason}}
    end
  end

  defp run_dispatcher_gate(parent_context, read_path, opts) do
    dispatcher_opts =
      [
        read_path: read_path,
        requested_tool: Keyword.get(opts, :requested_tool, :read_file),
        requested_tools: Keyword.get(opts, :requested_tools, ChildRunContract.read_only_tools()),
        stage: :real_readonly_child_spawn_gate
      ]
      |> maybe_put_opt(:remaining_warn_fuse_budget, opts)
      |> maybe_put_opt(:budget_source, opts)
      |> maybe_put_opt(:budget_policy, opts)
      |> maybe_put_opt(:capability_request, opts)

    ChildRunDispatcher.execute_runner_proof_gate(parent_context, dispatcher_opts)
  end

  defp child_opts(opts) do
    opts
    |> Keyword.take([:on_message, :output_schema])
    |> Keyword.put_new(:output_schema, AppServer.readonly_child_output_schema())
  end

  defp child_prompt(parent_context, dispatcher_proof, read_path) do
    child_input = ChildRunContract.filter_child_input(parent_context)

    """
    You are a bounded read-only diagnostic child for Symphony DTS-41.

    Adapter: #{@adapter_version}
    Issue: #{Map.get(child_input, :issue_identifier)}
    Bounded question: #{Map.get(child_input, :bounded_question)}
    Read targets:
    #{format_lines(Map.get(child_input, :read_targets, [read_path]))}

    Constraints:
    #{format_lines(Map.get(child_input, :constraints, []))}

    Effective read-only tools:
    #{format_lines(get_in(dispatcher_proof, [:effective_tool_grant, :allowed_tools]) || [])}

    Return only the requested schema with these fields: finding, checked_paths, confidence, risks_conflicts, recommended_parent_action. Do not write files, run shell commands, mutate git, mutate Linear, access Salesforce or other business systems, operate a browser, or spawn nested agents. Parent Runner owns synthesis, Evidence, memory, and status.
    """
  end

  defp completed_proof(parent_context, dispatcher_proof, child_result, read_path) do
    issue_identifier =
      parent_context
      |> ChildRunContract.filter_child_input()
      |> Map.get(:issue_identifier)

    child_session_id = result_value(child_result, :session_id)
    child_thread_id = result_value(child_result, :thread_id)
    child_turn_id = result_value(child_result, :turn_id)

    %{
      adapter_version: @adapter_version,
      status: :readonly_child_completed,
      decision: :accepted,
      stage: :real_readonly_child,
      proof_only: false,
      capability_enabled: false,
      spawn_real_child: true,
      child_session_id: child_session_id,
      child_thread_id: child_thread_id,
      child_turn_id: child_turn_id,
      read_path: read_path,
      effective_tool_grant: dispatcher_proof.effective_tool_grant,
      child_input_keys: dispatcher_proof.child_input_keys,
      parent_owns_synthesis: true,
      dispatcher_proof: dispatcher_proof,
      trace:
        real_child_trace(
          dispatcher_proof,
          read_path,
          child_session_id,
          child_thread_id,
          child_turn_id,
          issue_identifier
        )
    }
  end

  defp real_child_trace(
         dispatcher_proof,
         read_path,
         child_session_id,
         child_thread_id,
         child_turn_id,
         issue_identifier
       ) do
    [
      ChildRunTrace.event(:child_start, %{
        adapter_version: @adapter_version,
        issue_identifier: issue_identifier,
        proof_only: false,
        spawn_real_child: true,
        child_session_id: child_session_id,
        child_thread_id: child_thread_id,
        child_turn_id: child_turn_id
      }),
      ChildRunTrace.event(:effective_tool_grant, dispatcher_proof.effective_tool_grant),
      ChildRunTrace.event(:path_check, %{path: read_path, allowed: true}),
      ChildRunTrace.event(:budget_threshold, %{
        state: :ok,
        budget_source: dispatcher_proof.budget_source,
        remaining_warn_fuse_budget: dispatcher_proof.remaining_warn_fuse_budget
      }),
      ChildRunTrace.event(:tool_call_attempt, %{tool: :read_file, path: read_path}),
      ChildRunTrace.event(:child_terminal_state, %{
        state: :completed_readonly_child,
        decision: :accepted,
        terminal_blocker: false,
        child_session_id: child_session_id
      }),
      ChildRunTrace.event(:parent_synthesis, %{owner: :parent_runner, evidence_author: :parent_runner})
    ]
  end

  defp maybe_put_opt(opts, key, source_opts) do
    if Keyword.has_key?(source_opts, key) do
      Keyword.put(opts, key, Keyword.fetch!(source_opts, key))
    else
      opts
    end
  end

  defp result_value(result, key) when is_map(result) do
    Map.get(result, key) || Map.get(result, Atom.to_string(key))
  end

  defp format_lines(values) do
    values
    |> List.wrap()
    |> Enum.map_join("\n", &"- #{&1}")
  end
end
