defmodule SymphonyElixir.ChildRunTrace do
  @moduledoc """
  Trace/event helpers for proof-only child-run ledgers.
  """

  @required_event_types [
    :child_start,
    :effective_tool_grant,
    :tool_call_attempt,
    :tool_denied,
    :path_check,
    :budget_threshold,
    :child_terminal_state,
    :parent_synthesis,
    :stale_rejection,
    :stop_close
  ]

  @spec required_event_types() :: [atom()]
  def required_event_types, do: @required_event_types

  @spec event(atom(), map()) :: map()
  def event(type, attrs \\ %{}) when is_atom(type) and is_map(attrs) do
    %{
      event: type,
      at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      attrs: attrs
    }
  end

  @spec valid_run_ledger(map(), term()) :: [map()]
  def valid_run_ledger(contract, path) do
    [
      event(:child_start, %{
        issue_identifier: contract.child_input.issue_identifier,
        proof_only: contract.proof_only,
        spawn_real_child: contract.spawn_real_child
      }),
      event(:effective_tool_grant, contract.effective_tool_grant),
      event(:path_check, %{path: path, allowed: true}),
      event(:budget_threshold, %{state: :ok, used_tokens: 1_000}),
      event(:tool_call_attempt, %{tool: :read_file, path: path}),
      event(:child_terminal_state, %{state: :completed_readonly_proof}),
      event(:parent_synthesis, %{owner: :parent_runner, evidence_author: :parent_runner})
    ]
  end

  @spec denial_ledger(map(), atom() | String.t(), term(), keyword()) :: [map()]
  def denial_ledger(contract, requested_tool, path, opts \\ []) do
    path_allowed = Keyword.get(opts, :path_allowed, false)

    [
      event(:child_start, %{
        issue_identifier: contract.child_input.issue_identifier,
        proof_only: contract.proof_only,
        spawn_real_child: contract.spawn_real_child
      }),
      event(:effective_tool_grant, contract.effective_tool_grant),
      event(:path_check, %{path: path, allowed: path_allowed}),
      event(:tool_call_attempt, %{tool: requested_tool, path: path}),
      event(:tool_denied, %{tool: requested_tool, reason: :not_in_effective_read_only_grant}),
      event(:budget_threshold, %{state: :warning, used_tokens: 96_000}),
      event(:child_terminal_state, %{state: :denied_readonly_boundary}),
      event(:parent_synthesis, %{owner: :parent_runner, evidence_author: :parent_runner}),
      event(:stop_close, %{ledger_closed_by: :watchdog, state: :closed_at_stop_timestamp})
    ]
  end

  @spec covers_required_events?([map()]) :: boolean()
  def covers_required_events?(events) when is_list(events) do
    present =
      events
      |> Enum.map(& &1.event)
      |> MapSet.new()

    @required_event_types
    |> MapSet.new()
    |> MapSet.subset?(present)
  end

  @spec to_jsonl([term()]) :: String.t()
  def to_jsonl(events) when is_list(events) do
    events
    |> Enum.map_join("\n", &encode_json/1)
    |> Kernel.<>("\n")
  end

  defp encode_json(value) when is_map(value) do
    value
    |> Enum.map_join(",", fn {key, val} ->
      "#{encode_json(to_string(key))}:#{encode_json(val)}"
    end)
    |> then(&"{#{&1}}")
  end

  defp encode_json(value) when is_list(value) do
    value
    |> Enum.map_join(",", &encode_json/1)
    |> then(&"[#{&1}]")
  end

  defp encode_json(true), do: "true"
  defp encode_json(false), do: "false"
  defp encode_json(nil), do: "null"
  defp encode_json(value) when is_atom(value), do: encode_json(to_string(value))
  defp encode_json(value) when is_binary(value), do: "\"" <> json_escape(value) <> "\""
  defp encode_json(value) when is_integer(value) or is_float(value), do: to_string(value)

  defp json_escape(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end
end
