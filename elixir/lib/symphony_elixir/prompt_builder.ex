defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]
  @typep child_run_dispatcher_proof_result ::
           :not_requested | {:ok, map()} | {:error, map()} | {:error, term()}

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map()
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  @spec child_run_dispatcher_proof_block(child_run_dispatcher_proof_result()) :: String.t()
  def child_run_dispatcher_proof_block(:not_requested), do: ""

  def child_run_dispatcher_proof_block({:ok, proof}) when is_map(proof) do
    child_run_dispatcher_proof_block(:accepted, proof)
  end

  def child_run_dispatcher_proof_block({:error, proof}) when is_map(proof) do
    child_run_dispatcher_proof_block(:rejected, proof)
  end

  def child_run_dispatcher_proof_block({:error, reason}) do
    """

    ## Runner Child-Run Dispatcher Proof Gate

    - decision: rejected
    - reason: #{inspect(reason)}
    - spawn_real_child: false
    - parent_owns_synthesis: true
    """
  end

  defp child_run_dispatcher_proof_block(decision, proof) do
    denied_tools = proof.effective_tool_grant.denied_tools || []
    denied_classes = proof.effective_tool_grant.denied_tool_classes || []

    """

    ## Runner Child-Run Dispatcher Proof Gate

    - decision: #{decision}
    - status: #{proof.status}
    - stage: #{proof.stage}
    - proof_only: #{proof.proof_only}
    - capability_enabled: #{proof.capability_enabled}
    - spawn_real_child: #{proof.spawn_real_child}
    - terminal_blocker: #{Map.get(proof, :terminal_blocker, decision == :rejected)}
    - parent_owns_synthesis: #{proof.parent_owns_synthesis}
    - requested_tool: #{proof.requested_tool}
    - budget_source: #{Map.get(proof, :budget_source) || :none}
    - remaining_warn_fuse_budget: #{Map.get(proof, :remaining_warn_fuse_budget) || :none}
    - child_input_keys: #{Enum.join(proof.child_input_keys, ",")}
    - allowed_tools: #{Enum.join(proof.effective_tool_grant.allowed_tools, ",")}
    - denied_tools: #{Enum.join(denied_tools, ",")}
    - denied_tool_classes: #{Enum.join(denied_classes, ",")}
    - denial_reason: #{proof.denial_reason || :none}
    - trace_event_count: #{length(proof.trace)}

    The parent Runner remains the only writer, synthesizer, Evidence author, and Linear status mover.
    The Dispatcher proof gate must not spawn a child process, call platform subagent/fork APIs, or grant shell/write/git/Linear/browser/nested-agent tools.
    """
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
