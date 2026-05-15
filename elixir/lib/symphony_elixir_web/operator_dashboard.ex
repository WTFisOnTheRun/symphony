defmodule SymphonyElixirWeb.OperatorDashboard do
  @moduledoc """
  Builds the human operator dashboard payload from runtime, API, and ledger surfaces.
  """

  alias SymphonyElixirWeb.Presenter

  @default_logs_root "C:/Users/Elvis/Dev/dts-symphony-runner-logs"
  @state_api_url "http://127.0.0.1:4017/api/v1/state"
  @linear_issue_root "https://linear.app/elvisfu/issue"
  @payload_poll_ms 30_000
  @stale_after_seconds 180
  @max_tasks 18

  @milestone_order [
    "issue eligible",
    "issue claimed",
    "workspace prepared",
    "prompt built",
    "agent launched",
    "first event received",
    "heartbeat updated",
    "artifact/evidence path discovered",
    "verification started",
    "terminal state reached"
  ]

  @milestone_states ~w(pending running passed failed skipped blocked)
  @blocked_states ["blocked"]
  @review_states ["needs human", "needs_human", "in review", "review"]
  @terminal_states ["done", "complete", "completed", "terminal", "canceled", "cancelled", "superseded", "failed"]

  @type payload :: map()

  @spec payload(GenServer.name(), timeout(), keyword()) :: payload()
  def payload(orchestrator, snapshot_timeout_ms, opts \\ []) do
    generated_at = utc_now_iso8601()
    logs_root = logs_root(opts)
    api_payload = Presenter.state_payload(orchestrator, snapshot_timeout_ms)
    runtime_state = read_json(Path.join(logs_root, "runtime-state.json"))
    ledgers = read_ledgers(logs_root, runtime_state, Keyword.get(opts, :fixture_ledger_root))
    all_tasks = build_tasks(api_payload, runtime_state, ledgers)
    visible_tasks = Enum.take(all_tasks, @max_tasks)

    %{
      generated_at: generated_at,
      api: api_summary(api_payload),
      runtime: runtime_summary(runtime_state, logs_root, length(ledgers)),
      counts: counts(api_payload, runtime_state, all_tasks),
      tasks: visible_tasks,
      review_queue: review_queue(all_tasks),
      warnings: warnings(api_payload, runtime_state, generated_at),
      refresh: %{
        mode: "LiveView events plus file polling fallback",
        poll_interval_ms: @payload_poll_ms,
        poll_interval_seconds: div(@payload_poll_ms, 1_000),
        stale_after_seconds: @stale_after_seconds
      },
      debug: %{
        state_api_path: "/api/v1/state",
        state_api_url: @state_api_url,
        raw_api_label: "Raw JSON debug API"
      }
    }
  end

  defp review_queue(tasks) do
    tasks
    |> Enum.filter(&(&1.category in ["blocked", "in-review"]))
    |> Enum.sort_by(fn task ->
      {
        review_queue_rank(task.category),
        timestamp_sort_value(task.last_event_at || task.ended_at || task.started_at),
        task.issue_identifier
      }
    end)
  end

  defp review_queue_rank("blocked"), do: 0
  defp review_queue_rank("in-review"), do: 1
  defp review_queue_rank(_category), do: 2

  defp api_summary(%{error: %{code: code, message: message}, generated_at: generated_at}) do
    %{
      reachable: false,
      generated_at: generated_at,
      error_code: code,
      error_message: message,
      counts: %{running: 0, retrying: 0}
    }
  end

  defp api_summary(%{} = api_payload) do
    %{
      reachable: true,
      generated_at: value(api_payload, :generated_at),
      error_code: nil,
      error_message: nil,
      counts: value(api_payload, :counts) || %{running: 0, retrying: 0}
    }
  end

  defp runtime_summary(nil, logs_root, ledger_count) do
    %{
      available: false,
      logs_root: logs_root,
      generated_at: nil,
      mode: nil,
      dashboard_reachable: nil,
      latest_error: nil,
      ledger_count: ledger_count,
      stale?: true,
      age_seconds: nil
    }
  end

  defp runtime_summary(%{} = runtime_state, logs_root, ledger_count) do
    generated_at = value(runtime_state, "generated_at")

    %{
      available: true,
      logs_root: logs_root,
      generated_at: generated_at,
      mode: value(runtime_state, "mode"),
      dashboard_reachable: value(runtime_state, "dashboard_reachable"),
      latest_error: value(runtime_state, "latest_error") || value(runtime_state, "dashboard_error"),
      ledger_count: ledger_count,
      stale?: stale_timestamp?(generated_at),
      age_seconds: age_seconds(generated_at)
    }
  end

  defp counts(api_payload, runtime_state, tasks) do
    api_counts = value(api_payload, :counts) || %{}

    %{
      running: count_from(api_counts, :running, tasks, "active"),
      retrying: count_from(api_counts, :retrying, tasks, "retrying"),
      blocked: Enum.count(tasks, &(&1.category == "blocked")),
      in_review: Enum.count(tasks, &(&1.category == "in-review")),
      terminal: Enum.count(tasks, &(&1.category == "terminal")),
      recent: length(tasks),
      stale_ready: runtime_state |> value("stale_ready") |> list_count()
    }
  end

  defp count_from(counts, key, tasks, category) do
    case value(counts, key) do
      count when is_integer(count) -> count
      _ -> Enum.count(tasks, &(&1.category == category))
    end
  end

  defp warnings(api_payload, runtime_state, generated_at) do
    []
    |> maybe_add_warning(api_unreachable?(api_payload), %{
      level: "danger",
      title: "Dashboard API unavailable",
      detail: api_error_message(api_payload)
    })
    |> maybe_add_warning(runtime_state == nil, %{
      level: "warning",
      title: "Runtime heartbeat file missing",
      detail: "No runtime-state.json was readable from the configured DTS runner logs root."
    })
    |> maybe_add_warning(runtime_state != nil and stale_timestamp?(value(runtime_state, "generated_at")), %{
      level: "warning",
      title: "Runtime heartbeat is stale",
      detail: "Last runtime heartbeat was #{format_age(value(runtime_state, "generated_at"), generated_at)} ago."
    })
    |> maybe_add_warning(runtime_state != nil and value(runtime_state, "dashboard_reachable") == false, %{
      level: "danger",
      title: "Watchdog reports dashboard unreachable",
      detail: safe_text(value(runtime_state, "dashboard_error") || "The watchdog could not reach the local state API.")
    })
    |> Enum.reverse()
  end

  defp maybe_add_warning(warnings, true, warning), do: [warning | warnings]
  defp maybe_add_warning(warnings, _condition, _warning), do: warnings

  defp api_unreachable?(%{error: _error}), do: true
  defp api_unreachable?(_api_payload), do: false

  defp api_error_message(%{error: %{code: code, message: message}}), do: "#{code}: #{message}"
  defp api_error_message(_api_payload), do: nil

  defp build_tasks(api_payload, runtime_state, ledgers) do
    api_entries = api_entries(api_payload)
    runtime_entries = runtime_entries(runtime_state)
    ledger_entries = ledger_entries(ledgers)

    identifiers =
      (Map.keys(api_entries) ++ Map.keys(runtime_entries) ++ Map.keys(ledger_entries))
      |> Enum.uniq()

    identifiers
    |> Enum.map(fn identifier ->
      build_task(
        identifier,
        Map.get(api_entries, identifier, %{}),
        Map.get(runtime_entries, identifier, %{}),
        Map.get(ledger_entries, identifier, %{})
      )
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn task ->
      {
        category_rank(task.category),
        -timestamp_sort_value(task.last_event_at || task.ended_at || task.started_at),
        task.issue_identifier
      }
    end)
  end

  defp api_entries(%{error: _error}), do: %{}

  defp api_entries(%{} = api_payload) do
    running =
      api_payload
      |> value(:running)
      |> list()
      |> Enum.map(&{value(&1, :issue_identifier), Map.put(&1, :api_status, "running")})

    retrying =
      api_payload
      |> value(:retrying)
      |> list()
      |> Enum.map(&{value(&1, :issue_identifier), Map.put(&1, :api_status, "retrying")})

    blocked =
      api_payload
      |> value(:blocked)
      |> list()
      |> Enum.map(&{value(&1, :issue_identifier), Map.put(&1, :api_status, "blocked")})

    (running ++ retrying ++ blocked)
    |> Enum.reject(fn {identifier, _entry} -> blank?(identifier) end)
    |> Map.new()
  end

  defp runtime_entries(nil), do: %{}

  defp runtime_entries(%{} = runtime_state) do
    running =
      runtime_state
      |> value("running")
      |> list()
      |> Enum.map(&{value(&1, "issue_identifier"), Map.put(&1, "runtime_status", "running")})

    retrying =
      runtime_state
      |> value("retrying")
      |> list()
      |> Enum.map(&{value(&1, "issue_identifier"), Map.put(&1, "runtime_status", "retrying")})

    terminal = identifier_entries(value(runtime_state, "terminal"), "terminal")
    stale_ready = identifier_entries(value(runtime_state, "stale_ready"), "stale-ready")

    (running ++ retrying ++ terminal ++ stale_ready)
    |> Enum.reject(fn {identifier, _entry} -> blank?(identifier) end)
    |> Enum.reduce(%{}, fn {identifier, entry}, entries ->
      Map.update(entries, identifier, entry, &Map.merge(entry, &1))
    end)
  end

  defp identifier_entries(value, status) do
    value
    |> list()
    |> Enum.map(fn
      identifier when is_binary(identifier) ->
        {identifier, %{"issue_identifier" => identifier, "runtime_status" => status}}

      %{} = entry ->
        identifier = value(entry, "issue_identifier") || value(entry, "identifier")
        {identifier, Map.put(entry, "runtime_status", status)}

      _entry ->
        {nil, %{}}
    end)
  end

  defp ledger_entries(ledgers) do
    ledgers
    |> Enum.map(fn ledger -> {value(ledger, "issue_identifier"), ledger} end)
    |> Enum.reject(fn {identifier, _ledger} -> blank?(identifier) end)
    |> Map.new()
  end

  defp build_task(identifier, api_entry, runtime_entry, ledger) when is_binary(identifier) do
    state =
      first_present([
        value(ledger, "state"),
        value(api_entry, :state),
        value(runtime_entry, "state"),
        value(runtime_entry, "runtime_status"),
        value(api_entry, :api_status)
      ]) || "recent"

    workspace_path =
      first_safe_path([
        value(ledger, "workspace"),
        value(api_entry, :workspace_path),
        value(runtime_entry, "workspace_path")
      ])

    latest_output_path = first_safe_path([value(ledger, "latest_output_path")])
    evidence_paths = safe_paths(value(ledger, "evidence_paths"))
    review_path = latest_output_path || review_path_from_workspace(workspace_path)
    blocker_reason = safe_text(value(ledger, "blocker_reason") || value(ledger, "latest_error") || value(runtime_entry, "latest_error"))
    blocker_fingerprint = safe_text(value(ledger, "blocker_fingerprint"))
    category = task_category(state, api_entry, runtime_entry, blocker_reason, review_path, evidence_paths)
    milestones_built = milestones(value(ledger, "milestones"))

    %{
      issue_identifier: identifier,
      linear_url: "#{@linear_issue_root}/#{identifier}",
      state: safe_text(state),
      category: category,
      current_phase: safe_text(first_present([value(ledger, "phase"), value(ledger, "last_status_phase"), value(runtime_entry, "phase")])),
      started_at: first_present([value(ledger, "started_at"), value(api_entry, :started_at), value(runtime_entry, "started_at")]),
      ended_at: value(ledger, "ended_at"),
      last_event_at: first_present([value(ledger, "last_event_at"), value(api_entry, :last_event_at), value(runtime_entry, "last_event_at")]),
      last_event: safe_text(first_present([value(ledger, "last_event"), value(api_entry, :last_event), value(runtime_entry, "last_event")])),
      last_message: safe_text(first_present([value(ledger, "last_message"), value(api_entry, :last_message), value(runtime_entry, "last_message")])),
      workspace_path: workspace_path,
      latest_output_path: latest_output_path,
      review_path: review_path,
      evidence_paths: evidence_paths,
      blocker_reason: blocker_reason,
      blocker_fingerprint: blocker_fingerprint,
      blocker_hint: blocker_hint(blocker_fingerprint),
      next_human_action: next_human_action(ledger, category),
      action_kind: next_action_kind(category, blocker_fingerprint, review_path, evidence_paths),
      session_id: safe_text(first_present([value(ledger, "session_id"), value(api_entry, :session_id), value(runtime_entry, "session_id")])),
      turn_count: first_present([value(ledger, "turn_count"), value(api_entry, :turn_count), value(runtime_entry, "turn_count")]),
      tokens: tokens(ledger, api_entry, runtime_entry),
      milestones: milestones_built,
      milestone_summary: milestone_summary(milestones_built),
      history: history(value(ledger, "history")),
      sources: task_sources(api_entry, runtime_entry, ledger)
    }
  end

  defp build_task(_identifier, _api_entry, _runtime_entry, _ledger), do: nil

  defp task_category(state, api_entry, runtime_entry, blocker_reason, review_path, evidence_paths) do
    normalized = normalize_state(state)

    cond do
      not blank?(blocker_reason) or normalized in @blocked_states -> "blocked"
      normalized in @review_states -> "in-review"
      normalized in ["running", "in progress", "symphony ready"] -> "active"
      value(api_entry, :api_status) == "retrying" or value(runtime_entry, "runtime_status") == "retrying" -> "retrying"
      value(api_entry, :api_status) == "running" or value(runtime_entry, "runtime_status") == "running" -> "active"
      String.contains?(normalized, "retry") -> "retrying"
      normalized in @terminal_states -> "terminal"
      not blank?(review_path) or evidence_paths != [] -> "in-review"
      value(runtime_entry, "runtime_status") == "terminal" -> "terminal"
      value(runtime_entry, "runtime_status") == "stale-ready" -> "blocked"
      true -> "recent"
    end
  end

  defp category_rank("active"), do: 0
  defp category_rank("retrying"), do: 1
  defp category_rank("blocked"), do: 2
  defp category_rank("in-review"), do: 3
  defp category_rank("terminal"), do: 4
  defp category_rank(_category), do: 5

  defp tokens(ledger, api_entry, runtime_entry) do
    token_map = first_present([value(api_entry, :tokens), value(runtime_entry, "tokens"), value(ledger, "tokens")]) || %{}

    %{
      total_tokens: value(token_map, :total_tokens),
      input_tokens: value(token_map, :input_tokens),
      output_tokens: value(token_map, :output_tokens)
    }
  end

  defp milestones(milestone_map) when is_map(milestone_map) do
    extras =
      milestone_map
      |> Map.keys()
      |> Enum.reject(&(&1 in @milestone_order))
      |> Enum.sort()

    (@milestone_order ++ extras)
    |> Enum.map(fn name ->
      milestone = Map.get(milestone_map, name) || %{}
      state = milestone |> value("state") |> normalize_milestone_state()

      %{
        name: name,
        state: state,
        at: value(milestone, "at")
      }
    end)
  end

  defp milestones(_milestone_map) do
    Enum.map(@milestone_order, &%{name: &1, state: "pending", at: nil})
  end

  defp history(history_entries) do
    history_entries
    |> list()
    |> Enum.take(-3)
    |> Enum.map(fn entry ->
      %{
        at: value(entry, "at"),
        event: safe_text(value(entry, "event")),
        message: safe_text(value(entry, "message"))
      }
    end)
  end

  defp task_sources(api_entry, runtime_entry, ledger) do
    []
    |> maybe_source(api_entry != %{}, "api")
    |> maybe_source(runtime_entry != %{}, "runtime-state")
    |> maybe_source(ledger != %{}, "ledger")
    |> Enum.reverse()
  end

  defp maybe_source(sources, true, source), do: [source | sources]
  defp maybe_source(sources, _condition, _source), do: sources

  defp next_human_action(ledger, category) do
    case safe_text(value(ledger, "next_human_action")) do
      nil -> default_next_human_action(category)
      action -> action
    end
  end

  defp default_next_human_action("blocked"), do: "Resolve the blocker or update Linear before rerun."
  defp default_next_human_action("in-review"), do: "Review the listed evidence or REVIEW.md path."
  defp default_next_human_action("active"), do: "Monitor heartbeat and milestone movement."
  defp default_next_human_action("retrying"), do: "Watch retry result; intervene only if the blocker repeats."
  defp default_next_human_action(_category), do: "No next action recorded."

  defp next_action_kind(category, blocker_fingerprint, review_path, evidence_paths) do
    cond do
      runtime_fingerprint?(blocker_fingerprint) -> :repair_runtime
      write_scope_fingerprint?(blocker_fingerprint) -> :repair_write_scope
      category == "blocked" -> :rerelease
      category == "in-review" and present?(review_path) -> :open_review
      category == "in-review" and evidence_paths != [] -> :open_evidence
      true -> :monitor
    end
  end

  defp blocker_hint(blocker_fingerprint) when is_binary(blocker_fingerprint) do
    cond do
      runtime_fingerprint?(blocker_fingerprint) ->
        "Run preflight (`where.exe mise`, `mise exec -- mix --version`, `Test-Path erlexec.dll`) and write RUNTIME_PREFLIGHT_EVIDENCE.md with PASS markers under the run folder."

      write_scope_fingerprint?(blocker_fingerprint) ->
        "Revert the unauthorized writes in `symphony\\elixir` OR update the Goal Contract to explicitly name those paths, then re-release."

      String.contains?(blocker_fingerprint, "format") ->
        "Format only the in-scope files, OR add a Validation Scope Amendment to the Goal Contract that narrows the format gate to authorized paths."

      true ->
        nil
    end
  end

  defp blocker_hint(_blocker_fingerprint), do: nil

  defp runtime_fingerprint?(fingerprint) when is_binary(fingerprint) do
    String.starts_with?(fingerprint, "runtime_verification_unavailable")
  end

  defp runtime_fingerprint?(_fingerprint), do: false

  defp write_scope_fingerprint?(fingerprint) when is_binary(fingerprint) do
    String.contains?(fingerprint, "write_scope") or String.contains?(fingerprint, "unauthorized")
  end

  defp write_scope_fingerprint?(_fingerprint), do: false

  defp milestone_summary(milestones) when is_list(milestones) do
    total = length(milestones)
    passed = Enum.count(milestones, &(&1.state == "passed"))
    %{passed: passed, total: total}
  end

  defp milestone_summary(_milestones), do: %{passed: 0, total: 0}

  defp read_ledgers(logs_root, runtime_state, fixture_ledger_root) do
    logs_root
    |> ledger_paths(runtime_state, fixture_ledger_root)
    |> Enum.map(&read_json/1)
    |> Enum.reject(&is_nil/1)
  end

  defp ledger_paths(logs_root, runtime_state, fixture_ledger_root) do
    runtime_paths =
      runtime_state
      |> value("ledgers")
      |> list()

    log_paths =
      logs_root
      |> Path.join("ledger")
      |> Path.join("*.json")
      |> Path.wildcard()

    fixture_paths =
      case fixture_ledger_root do
        root when is_binary(root) and root != "" ->
          root |> Path.join("*.json") |> Path.wildcard()

        _ ->
          []
      end

    (runtime_paths ++ log_paths ++ fixture_paths)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp read_json(path) when is_binary(path) do
    with {:ok, body} <- File.read(path),
         {:ok, json} <- decode_json_body(body),
         true <- is_map(json) do
      json
    else
      _ -> nil
    end
  end

  defp read_json(_path), do: nil

  defp decode_json_body(<<0xEF, 0xBB, 0xBF, body::binary>>), do: Jason.decode(body)

  defp decode_json_body(<<0xFF, 0xFE, body::binary>>) do
    body
    |> :unicode.characters_to_binary({:utf16, :little}, :utf8)
    |> decode_converted_json_body()
  end

  defp decode_json_body(<<0xFE, 0xFF, body::binary>>) do
    body
    |> :unicode.characters_to_binary({:utf16, :big}, :utf8)
    |> decode_converted_json_body()
  end

  defp decode_json_body(body), do: Jason.decode(body)

  defp decode_converted_json_body(body) when is_binary(body), do: Jason.decode(body)
  defp decode_converted_json_body(_body), do: {:error, :invalid_encoding}

  defp logs_root(opts) do
    opts
    |> Keyword.get(:dts_logs_root)
    |> case do
      root when is_binary(root) and root != "" ->
        root

      _ ->
        logs_root_from_log_file() || @default_logs_root
    end
  end

  defp logs_root_from_log_file do
    case Application.get_env(:symphony_elixir, :log_file) do
      log_file when is_binary(log_file) and log_file != "" ->
        log_file
        |> Path.dirname()
        |> Path.dirname()

      _ ->
        nil
    end
  end

  defp review_path_from_workspace(nil), do: nil

  defp review_path_from_workspace(workspace_path) do
    review_path = Path.join(workspace_path, "REVIEW.md")

    if File.exists?(review_path), do: safe_operator_path(review_path)
  end

  defp safe_paths(paths) do
    paths
    |> list()
    |> Enum.map(&safe_operator_path/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp first_safe_path(paths) do
    paths
    |> Enum.map(&safe_operator_path/1)
    |> Enum.find(&present?/1)
  end

  defp safe_operator_path(path) when is_binary(path) do
    normalized = String.downcase(path)

    blocked_patterns = [
      "\\sources\\",
      "/sources/",
      "cookie",
      "secret",
      "api_key",
      "apikey",
      "token.json",
      ".env"
    ]

    if String.contains?(normalized, blocked_patterns) do
      nil
    else
      String.slice(path, 0, 260)
    end
  end

  defp safe_operator_path(_path), do: nil

  defp safe_text(nil), do: nil

  defp safe_text(value) do
    value
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> nil
      text -> String.slice(text, 0, 240)
    end
  end

  defp first_present(values), do: Enum.find(values, &present?/1)

  defp present?(value), do: not blank?(value)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp list(nil), do: []
  defp list(value) when is_list(value), do: value
  defp list(value), do: [value]

  defp list_count(value), do: value |> list() |> length()

  defp value(nil, _key), do: nil

  defp value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || atom_key_value(map, key)
  end

  defp value(_map, _key), do: nil

  defp atom_key_value(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp normalize_state(state) do
    state
    |> safe_text()
    |> case do
      nil -> ""
      text -> text |> String.downcase() |> String.replace("-", " ")
    end
  end

  defp normalize_milestone_state(state) do
    state = normalize_state(state)

    if state in @milestone_states do
      state
    else
      "pending"
    end
  end

  defp stale_timestamp?(timestamp) do
    case age_seconds(timestamp) do
      seconds when is_integer(seconds) -> seconds > @stale_after_seconds
      _ -> true
    end
  end

  defp age_seconds(timestamp) do
    with {:ok, datetime} <- parse_datetime(timestamp) do
      DateTime.diff(DateTime.utc_now(), datetime, :second)
    else
      _ -> nil
    end
  end

  defp format_age(timestamp, generated_at) do
    reference_time =
      case parse_datetime(generated_at) do
        {:ok, datetime} -> datetime
        _ -> DateTime.utc_now()
      end

    case parse_datetime(timestamp) do
      {:ok, datetime} ->
        seconds = DateTime.diff(reference_time, datetime, :second) |> max(0)
        "#{div(seconds, 60)}m #{rem(seconds, 60)}s"

      _ ->
        "unknown"
    end
  end

  defp timestamp_sort_value(timestamp) do
    case parse_datetime(timestamp) do
      {:ok, datetime} -> DateTime.to_unix(datetime)
      _ -> 0
    end
  end

  defp parse_datetime(%DateTime{} = datetime), do: {:ok, datetime}

  defp parse_datetime(timestamp) when is_binary(timestamp) and timestamp != "" do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp parse_datetime(_timestamp), do: :error

  defp utc_now_iso8601 do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
