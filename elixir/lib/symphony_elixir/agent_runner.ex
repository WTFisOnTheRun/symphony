defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer

  alias SymphonyElixir.{
    ChildRunContract,
    ChildRunDispatcher,
    Config,
    Linear.Issue,
    OperatorInputHandoff,
    PromptBuilder,
    Tracker,
    Workspace
  }

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(workspace, issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc false
  @spec build_turn_prompt_for_test(Path.t(), Issue.t(), keyword()) :: String.t()
  def build_turn_prompt_for_test(workspace, issue, opts \\ []) do
    build_turn_prompt(workspace, issue, opts, 1, 1)
  end

  @doc false
  @spec child_run_dispatcher_proof_for_test(Issue.t(), keyword()) ::
          :not_requested | {:ok, map()} | {:error, map()} | {:error, term()}
  def child_run_dispatcher_proof_for_test(%Issue{} = issue, opts \\ []) do
    child_run_dispatcher_proof(issue, opts)
  end

  defp build_turn_prompt(workspace, issue, opts, 1, _max_turns) do
    child_run_proof = child_run_dispatcher_proof(issue, opts)

    PromptBuilder.build_prompt(issue, opts) <>
      PromptBuilder.child_run_dispatcher_proof_block(child_run_proof) <>
      OperatorInputHandoff.prompt_context(workspace, issue)
  end

  defp build_turn_prompt(_workspace, _issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp child_run_dispatcher_proof(%Issue{} = issue, opts) do
    description = issue.description || ""

    if child_run_proof_requested?(description) or Keyword.get(opts, :force_child_run_proof, false) do
      read_path = Keyword.get(opts, :read_path, synthetic_child_run_read_path(issue))

      dispatcher_opts = [
        capability_request: child_run_capability_request(description, opts),
        read_path: read_path,
        requested_tool: Keyword.get(opts, :requested_tool, requested_child_tool(description)),
        requested_tools: Keyword.get(opts, :requested_tools, requested_child_tools(description)),
        remaining_warn_fuse_budget:
          Keyword.get(
            opts,
            :remaining_warn_fuse_budget,
            parsed_integer_field(description, "remaining_warn_fuse_budget") || 520_000
          ),
        budget_policy: budget_policy_from_description(description),
        stage: :runner_control_flow_proof
      ]

      issue
      |> child_run_parent_context(read_path)
      |> ChildRunDispatcher.execute_runner_proof_gate(dispatcher_opts)
    else
      :not_requested
    end
  end

  defp child_run_proof_requested?(description) when is_binary(description) do
    normalized = String.downcase(description)

    read_only_proof_request? =
      String.contains?(normalized, "read-only child-run") and
        String.contains?(normalized, "proof") and
        (String.contains?(normalized, "dispatcher") or String.contains?(normalized, "proof gate"))

    read_only_proof_request? or bare_subagent_fork_request?(description) or
      requested_child_tools_declared?(description)
  end

  defp bare_subagent_fork_request?(description) when is_binary(description) do
    description
    |> String.split(~r/\R/, trim: true)
    |> Enum.any?(fn line ->
      normalized =
        line
        |> String.trim()
        |> String.downcase()

      bare_bullet? =
        Regex.match?(~r/^[-*]\s*`?subagent[-_]fork`?\s*(:.*)?$/, normalized) and
          not (String.contains?(normalized, "read-only") and String.contains?(normalized, "proof"))

      direct_request? =
        Regex.match?(~r/^requested capability\s*:\s*`?subagent[-_]fork`?\s*$/, normalized)

      bare_bullet? or direct_request?
    end)
  end

  defp requested_child_tools_declared?(description) when is_binary(description) do
    Regex.match?(~r/(?im)^\s*(requested child tools|child tools|requested_tools)\s*:/, description)
  end

  defp child_run_capability_request(description, opts) do
    Keyword.get(opts, :capability_request) ||
      if bare_subagent_fork_request?(description) do
        :subagent_fork
      else
        :subagent_fork_readonly_proof_only
      end
  end

  defp requested_child_tool(description) do
    description
    |> requested_child_tools()
    |> List.first(:read_file)
  end

  defp requested_child_tools(description) do
    case Regex.run(~r/(?im)^\s*(?:requested child tools|child tools|requested_tools)\s*:\s*(.+)$/, description) do
      [_, raw_tools] ->
        raw_tools
        |> String.split([",", ";"], trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        ChildRunContract.read_only_tools()
    end
  end

  defp budget_policy_from_description(description) do
    ChildRunContract.default_budget_policy()
    |> maybe_put_integer(:child_token_budget, description)
    |> maybe_put_integer(:child_output_cap_tokens, description)
    |> maybe_put_integer(:total_child_pool_max_tokens, description)
    |> maybe_put_integer(:parent_synthesis_reserve_tokens, description)
  end

  defp maybe_put_integer(policy, key, description) do
    case parsed_integer_field(description, Atom.to_string(key)) do
      value when is_integer(value) -> Map.put(policy, key, value)
      nil -> policy
    end
  end

  defp parsed_integer_field(description, field_name) do
    pattern = Regex.compile!("(?im)^\\s*#{Regex.escape(field_name)}\\s*:\\s*([0-9_,]+)\\s*$")

    case Regex.run(pattern, description) do
      [_, raw_value] ->
        raw_value
        |> String.replace(~r/[_,]/, "")
        |> Integer.parse()
        |> case do
          {value, ""} -> value
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp child_run_parent_context(%Issue{} = issue, read_path) do
    description = issue.description || ""

    %{
      issue_identifier: issue.identifier,
      goal: issue.title || "Runner child-run proof gate",
      bounded_question: "Return the Dispatcher proof decision for this bounded read-only request.",
      read_targets: [read_path],
      source_refs: ["Linear issue #{issue.identifier} Goal Contract"],
      constraints: [
        "proof-only",
        "read-only effective tool grant",
        "parent runner owns synthesis and Evidence"
      ],
      parent_revision: parent_revision(issue),
      messages: [description],
      parent_history: description,
      raw_transcript: "protected diagnostic only"
    }
  end

  defp synthetic_child_run_read_path(%Issue{identifier: identifier}) when is_binary(identifier) do
    "synthetic://#{String.downcase(identifier)}/child-run-dispatcher-proof.md"
  end

  defp synthetic_child_run_read_path(_issue), do: "synthetic://issue/child-run-dispatcher-proof.md"

  defp parent_revision(%Issue{updated_at: %DateTime{} = updated_at}), do: DateTime.to_iso8601(updated_at)
  defp parent_revision(%Issue{id: id}) when is_binary(id), do: id
  defp parent_revision(%Issue{identifier: identifier}) when is_binary(identifier), do: identifier
  defp parent_revision(_issue), do: "initial"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
