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
  @codex_thread_goal_capability_id "codex-thread-goal-bridge"

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

    case codex_thread_goal_contract(issue) do
      {:ok, codex_thread_goal} ->
        case child_run_pre_turn_gate(issue, opts) do
          {:allow, child_run_proof} ->
            opts = Keyword.put(opts, :child_run_dispatcher_proof_result, child_run_proof)

            with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
              try do
                with :ok <- maybe_set_codex_thread_goal(session, issue, codex_thread_goal, codex_update_recipient) do
                  do_run_codex_turns(
                    session,
                    workspace,
                    issue,
                    codex_update_recipient,
                    opts,
                    issue_state_fetcher,
                    1,
                    max_turns
                  )
                end
              after
                AppServer.stop_session(session)
              end
            end

          {:block, proof} ->
            Logger.warning("Child-run Dispatcher blocked pre-turn for #{issue_context(issue)} proof=#{inspect(terminal_blocker_summary(proof))}")
            send_child_run_blocked_update(codex_update_recipient, issue, proof)
            {:error, {:child_run_dispatcher_pre_turn_blocked, terminal_blocker_summary(proof)}}

          {:error, reason} ->
            Logger.warning("Child-run Dispatcher failed pre-turn for #{issue_context(issue)} reason=#{inspect(reason)}")
            {:error, {:child_run_dispatcher_pre_turn_blocked, reason}}
        end

      {:error, reason} ->
        Logger.warning("Codex thread goal contract blocked pre-turn for #{issue_context(issue)} reason=#{inspect(reason)}")
        send_codex_thread_goal_blocked_update(codex_update_recipient, issue, reason)
        {:error, {:codex_thread_goal_contract_invalid, reason}}
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
  @spec child_run_pre_turn_gate_for_test(Issue.t(), keyword()) ::
          {:allow, :not_requested | {:ok, map()}} | {:block, map()} | {:error, term()}
  def child_run_pre_turn_gate_for_test(%Issue{} = issue, opts \\ []) do
    child_run_pre_turn_gate(issue, opts)
  end

  @doc false
  @spec child_run_dispatcher_proof_for_test(Issue.t(), keyword()) ::
          :not_requested | {:ok, map()} | {:error, map()} | {:error, term()}
  def child_run_dispatcher_proof_for_test(%Issue{} = issue, opts \\ []) do
    child_run_dispatcher_proof(issue, opts)
  end

  @doc false
  @spec codex_thread_goal_contract_for_test(Issue.t()) :: {:ok, :not_requested | map()} | {:error, term()}
  def codex_thread_goal_contract_for_test(%Issue{} = issue) do
    codex_thread_goal_contract(issue)
  end

  defp build_turn_prompt(workspace, issue, opts, 1, _max_turns) do
    child_run_proof = child_run_dispatcher_proof_result(issue, opts)

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

  defp maybe_set_codex_thread_goal(_session, _issue, :not_requested, _recipient), do: :ok

  defp maybe_set_codex_thread_goal(session, issue, %{objective: objective} = goal_contract, recipient) do
    opts =
      case Map.get(goal_contract, :token_budget) do
        nil -> []
        token_budget -> [token_budget: token_budget]
      end

    case AppServer.set_goal(session, objective, opts) do
      {:ok, goal} ->
        send_codex_update(recipient, issue, %{
          event: :codex_thread_goal_set,
          goal: codex_thread_goal_summary(goal),
          timestamp: DateTime.utc_now()
        })

        :ok

      {:error, reason} ->
        send_codex_update(recipient, issue, %{
          event: :codex_thread_goal_set_failed,
          reason: reason,
          timestamp: DateTime.utc_now()
        })

        {:error, {:codex_thread_goal_set_failed, reason}}
    end
  end

  defp codex_thread_goal_summary(goal) when is_map(goal) do
    Map.take(goal, ["threadId", "objective", "status", "tokenBudget", "tokensUsed", "timeUsedSeconds"])
  end

  defp codex_thread_goal_contract(%Issue{description: description}) when is_binary(description) do
    case markdown_section(description, "Codex Thread Goal") do
      :not_found ->
        {:ok, :not_requested}

      {:ok, section_body} ->
        with :ok <- require_codex_thread_goal_capability(description) do
          parse_codex_thread_goal_section(section_body)
        end
    end
  end

  defp codex_thread_goal_contract(%Issue{}), do: {:ok, :not_requested}

  defp parse_codex_thread_goal_section(section_body) when is_binary(section_body) do
    fields = section_fields(section_body)

    with {:ok, objective} <- required_section_field(fields, "objective"),
         {:ok, token_budget} <- optional_token_budget(fields) do
      {:ok, %{objective: objective, token_budget: token_budget}}
    end
  end

  defp require_codex_thread_goal_capability(description) when is_binary(description) do
    case markdown_section(description, "Required Capabilities") do
      {:ok, section_body} ->
        if capability_requested?(section_body, @codex_thread_goal_capability_id) do
          :ok
        else
          {:error, {:missing_codex_thread_goal_capability_request, @codex_thread_goal_capability_id}}
        end

      :not_found ->
        {:error, {:missing_codex_thread_goal_capability_request, @codex_thread_goal_capability_id}}
    end
  end

  defp capability_requested?(section_body, capability_id) when is_binary(section_body) and is_binary(capability_id) do
    requested_id_pattern = Regex.compile!("(^|[^a-z0-9_-])`?#{Regex.escape(capability_id)}`?([^a-z0-9_-]|$)")

    section_body
    |> String.split("\n")
    |> Enum.any?(fn line ->
      line
      |> String.trim()
      |> String.downcase()
      |> then(&Regex.match?(requested_id_pattern, &1))
    end)
  end

  defp required_section_field(fields, field_name) when is_map(fields) and is_binary(field_name) do
    case Map.get(fields, field_name) do
      nil -> {:error, {:missing_codex_thread_goal_field, field_name}}
      "" -> {:error, {:empty_codex_thread_goal_field, field_name}}
      value -> {:ok, value}
    end
  end

  defp optional_token_budget(fields) when is_map(fields) do
    case Map.get(fields, "token_budget") || Map.get(fields, "tokenbudget") do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      raw ->
        case Integer.parse(raw) do
          {token_budget, ""} when token_budget > 0 -> {:ok, token_budget}
          _ -> {:error, {:invalid_codex_thread_goal_token_budget, raw}}
        end
    end
  end

  defp section_fields(section_body) when is_binary(section_body) do
    section_body
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, fields ->
      line
      |> String.trim()
      |> String.replace(~r/^\s*[-*]\s*/, "")
      |> String.split(":", parts: 2)
      |> case do
        [key, value] ->
          Map.put_new(fields, normalize_section_field_key(key), String.trim(value))

        _ ->
          fields
      end
    end)
  end

  defp normalize_section_field_key(key) when is_binary(key) do
    key
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
  end

  defp markdown_section(description, section_title) when is_binary(description) and is_binary(section_title) do
    lines = String.split(description, "\n")

    case Enum.find_index(lines, &markdown_heading_title?(&1, section_title)) do
      nil ->
        :not_found

      index ->
        heading_level = lines |> Enum.at(index) |> markdown_heading_level()

        body =
          lines
          |> Enum.drop(index + 1)
          |> Enum.take_while(fn line ->
            case markdown_heading_level(line) do
              nil -> true
              level -> level > heading_level
            end
          end)
          |> Enum.join("\n")
          |> String.trim()

        {:ok, body}
    end
  end

  defp markdown_heading_title?(line, expected_title) when is_binary(line) and is_binary(expected_title) do
    case markdown_heading(line) do
      {_level, title} -> normalize_markdown_heading_title(title) == normalize_markdown_heading_title(expected_title)
      nil -> false
    end
  end

  defp markdown_heading_level(line) when is_binary(line) do
    case markdown_heading(line) do
      {level, _title} -> level
      nil -> nil
    end
  end

  defp markdown_heading(line) when is_binary(line) do
    case Regex.run(~r/^(#+)\s+(.+?)\s*#*\s*$/, String.trim(line), capture: :all_but_first) do
      [markers, title] ->
        level = String.length(markers)

        if level in 2..6 do
          {level, title}
        end

      _ ->
        nil
    end
  end

  defp normalize_markdown_heading_title(title) when is_binary(title) do
    title
    |> String.trim()
    |> String.downcase()
  end

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

      budget_field_present? = Keyword.has_key?(opts, :remaining_warn_fuse_budget)
      parsed_budget = parsed_integer_or_raw_field(description, "remaining_warn_fuse_budget")

      remaining_warn_fuse_budget =
        if budget_field_present?, do: Keyword.fetch!(opts, :remaining_warn_fuse_budget), else: parsed_budget

      budget_source_field_present? = Keyword.has_key?(opts, :budget_source)

      parsed_budget_source =
        parsed_budget_source(description, "budget_source") ||
          parsed_budget_source(description, "remaining_warn_fuse_budget_source")

      budget_source =
        if budget_source_field_present?, do: Keyword.fetch!(opts, :budget_source), else: parsed_budget_source

      dispatcher_opts =
        [
          capability_request: child_run_capability_request(description, opts),
          read_path: read_path,
          requested_tool: Keyword.get(opts, :requested_tool, requested_child_tool(description)),
          requested_tools: Keyword.get(opts, :requested_tools, requested_child_tools(description)),
          budget_policy: budget_policy_from_description(description),
          stage: :runner_control_flow_proof
        ]
        |> maybe_put_dispatcher_opt(
          :remaining_warn_fuse_budget,
          remaining_warn_fuse_budget,
          budget_field_present? or not is_nil(parsed_budget)
        )
        |> maybe_put_dispatcher_opt(
          :budget_source,
          budget_source,
          budget_source_field_present? or not is_nil(parsed_budget_source)
        )

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
    Regex.match?(
      ~r/(?im)^\s*(requested child tools|child tools|requested_tools|allowed_child_tools|effective_tool_grant|effective_child_tool_grant|effective_tool_grant\.(allowed_tools|denied_tools|allowed_child_tools))\s*:/,
      description
    )
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
    flat_tools =
      description
      |> parsed_tool_fields([
        "requested child tools",
        "child tools",
        "requested_tools",
        "allowed_child_tools",
        "effective_tool_grant.allowed_tools",
        "effective_tool_grant.denied_tools",
        "effective_tool_grant.allowed_child_tools"
      ])

    tools = flat_tools ++ parsed_nested_tool_grant_fields(description)

    case tools do
      [] -> ChildRunContract.read_only_tools()
      tools -> tools
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
    case parsed_integer_or_raw_field(description, field_name) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp parsed_integer_or_raw_field(description, field_name) do
    pattern = Regex.compile!("(?im)^\\s*#{Regex.escape(field_name)}\\s*:\\s*(-?[0-9_,]+|[^\\r\\n]+)\\s*$")

    case Regex.scan(pattern, description, capture: :all_but_first) do
      matches when matches != [] ->
        [raw_value] = List.last(matches)

        parsed =
          raw_value
          |> String.trim()
          |> String.replace(~r/[_,]/, "")
          |> Integer.parse()

        case parsed do
          {value, ""} -> value
          _ -> String.trim(raw_value)
        end

      [] ->
        nil
    end
  end

  defp parsed_budget_source(description, field_name) do
    pattern = Regex.compile!("(?im)^\\s*#{Regex.escape(field_name)}\\s*:\\s*([^\\r\\n]+)\\s*$")

    case Regex.scan(pattern, description, capture: :all_but_first) do
      matches when matches != [] ->
        [raw_source] = List.last(matches)

        raw_source
        |> String.trim()
        |> String.trim(" \"'`")

      [] ->
        nil
    end
  end

  defp parsed_tool_fields(description, field_names) do
    field_names
    |> Enum.flat_map(fn field_name ->
      pattern = Regex.compile!("(?im)^\\s*#{Regex.escape(field_name)}\\s*:\\s*(.+)$")

      description
      |> then(&Regex.scan(pattern, &1, capture: :all_but_first))
      |> Enum.flat_map(fn [raw_tools] -> parse_tool_list(raw_tools) end)
    end)
  end

  defp parsed_nested_tool_grant_fields(description) do
    description
    |> nested_tool_grant_blocks()
    |> Enum.flat_map(fn block ->
      Regex.scan(~r/(?im)^\s*(allowed_tools|denied_tools|allowed_child_tools)\s*:\s*(.+)$/, block, capture: :all_but_first)
    end)
    |> Enum.flat_map(fn [_field_name, raw_tools] -> parse_tool_list(raw_tools) end)
  end

  defp nested_tool_grant_blocks(description) do
    Regex.scan(
      ~r/(?ims)^\s*(?:effective_tool_grant|effective_child_tool_grant)\s*:\s*((?:\R[ \t]+[a-zA-Z0-9_.-]+\s*:\s*[^\r\n]+)+)/,
      description,
      capture: :all_but_first
    )
    |> Enum.map(fn [block] -> block end)
  end

  defp parse_tool_list(raw_tools) do
    raw_tools
    |> String.trim()
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split(~r/[,;\n]/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.trim(&1, " \"'`"))
    |> Enum.reject(&(&1 == ""))
  end

  defp child_run_dispatcher_proof_result(%Issue{} = issue, opts) do
    case Keyword.fetch(opts, :child_run_dispatcher_proof_result) do
      {:ok, child_run_proof} -> child_run_proof
      :error -> child_run_dispatcher_proof(issue, opts)
    end
  end

  defp child_run_pre_turn_gate(%Issue{} = issue, opts) do
    case child_run_dispatcher_proof(issue, opts) do
      {:error, proof} when is_map(proof) -> {:block, proof}
      {:error, reason} -> {:error, reason}
      child_run_proof -> {:allow, child_run_proof}
    end
  end

  defp send_child_run_blocked_update(recipient, issue, proof) do
    send_codex_update(recipient, issue, %{
      event: :child_run_dispatcher_pre_turn_blocked,
      proof: terminal_blocker_summary(proof),
      timestamp: DateTime.utc_now()
    })
  end

  defp send_codex_thread_goal_blocked_update(recipient, issue, reason) do
    send_codex_update(recipient, issue, %{
      event: :codex_thread_goal_pre_turn_blocked,
      reason: reason,
      timestamp: DateTime.utc_now()
    })
  end

  defp terminal_blocker_summary(proof) when is_map(proof) do
    Map.take(proof, [
      :decision,
      :status,
      :stage,
      :denial_reason,
      :terminal_blocker,
      :proof_only,
      :capability_enabled,
      :spawn_real_child,
      :budget_source,
      :remaining_warn_fuse_budget,
      :effective_tool_grant,
      :parent_owns_synthesis
    ])
  end

  defp maybe_put_dispatcher_opt(opts, _key, _value, false), do: opts
  defp maybe_put_dispatcher_opt(opts, key, value, true), do: Keyword.put(opts, key, value)

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
