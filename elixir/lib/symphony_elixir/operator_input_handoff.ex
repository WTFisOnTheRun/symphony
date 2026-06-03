defmodule SymphonyElixir.OperatorInputHandoff do
  @moduledoc """
  Durable handoff packet for Codex operator-input blockers.
  """

  alias SymphonyElixir.{Config, PathSafety}
  alias SymphonyElixir.Linear.Issue

  @fingerprint "operator_input_required"
  @handoff_dir ".symphony"
  @blocker_packet "operator-input-blocker.json"
  @input_candidates [
    ".symphony/operator-input-response.json",
    ".symphony/operator-input-response.md",
    "OPERATOR_INPUT.md",
    "operator-input-response.md"
  ]

  @spec fingerprint() :: String.t()
  def fingerprint, do: @fingerprint

  @spec persist_blocker(map()) :: {:ok, map()} | {:error, term()}
  def persist_blocker(blocked_entry) when is_map(blocked_entry) do
    with {:ok, workspace} <- packet_workspace(blocked_entry),
         :ok <- File.mkdir_p(Path.join(workspace, @handoff_dir)),
         packet <- build_packet(blocked_entry, workspace),
         packet_path <- blocker_packet_path(workspace),
         :ok <- File.write(packet_path, Jason.encode_to_iodata!(packet, pretty: true)) do
      {:ok, Map.put(packet, "packet_path", packet_path)}
    else
      {:error, reason} ->
        {:error, reason}

      reason ->
        {:error, reason}
    end
  end

  @spec comment_body(map(), {:ok, map()} | {:error, term()}, String.t()) :: String.t()
  def comment_body(blocked_entry, packet_result, handoff_state) do
    issue = Map.get(blocked_entry, :issue)
    identifier = issue_identifier(blocked_entry)
    request = request_summary(blocked_entry)

    packet_line =
      case packet_result do
        {:ok, %{"packet_path" => packet_path}} -> packet_path
        {:error, reason} -> "packet write failed: #{inspect(reason)}"
      end

    """
    ## Symphony blocked: operator input required

    blocker_fingerprint: #{@fingerprint}
    issue_id: #{issue_id(blocked_entry)}
    issue_identifier: #{identifier}
    current_linear_state: #{issue_state(issue)}
    workspace_path: #{workspace_path(blocked_entry)}
    durable_packet: #{packet_line}
    session_id: #{blank_to_na(Map.get(blocked_entry, :session_id))}
    thread_id: #{blank_to_na(extract_thread_id(blocked_entry))}
    turn_id: #{blank_to_na(extract_turn_id(blocked_entry))}

    Next Elvis action: provide the missing input in `.symphony/operator-input-response.md` or `OPERATOR_INPUT.md`, then move the issue back to Symphony Ready.
    Re-release rule: only return this issue to an active pickup state after durable input exists; the next pickup starts one new attempt and must read the blocker/input packet before acting. This is not a live Codex thread resume.
    Linear handoff state requested: #{handoff_state}

    Input request or approval summary:

    ```json
    #{Jason.encode!(request, pretty: true)}
    ```
    """
  end

  @spec unresolved_blocker?(Issue.t()) :: boolean()
  def unresolved_blocker?(%Issue{} = issue) do
    case packet_workspace(issue) do
      {:ok, workspace} ->
        File.exists?(blocker_packet_path(workspace)) and is_nil(input_response_path(workspace))

      {:error, _reason} ->
        false
    end
  end

  def unresolved_blocker?(_issue), do: false

  @spec prompt_context(Path.t(), Issue.t() | nil) :: String.t()
  def prompt_context(workspace, issue \\ nil)

  def prompt_context(workspace, issue) when is_binary(workspace) do
    workspace_candidates(workspace, issue)
    |> Enum.find_value(&prompt_context_from_workspace/1)
    |> case do
      nil -> ""
      context -> "\n\n" <> context
    end
  end

  def prompt_context(_workspace, _issue), do: ""

  @spec blocker_packet_path(Path.t()) :: Path.t()
  def blocker_packet_path(workspace) when is_binary(workspace) do
    Path.join([workspace, @handoff_dir, @blocker_packet])
  end

  @spec input_response_path(Path.t()) :: Path.t() | nil
  def input_response_path(workspace) when is_binary(workspace) do
    @input_candidates
    |> Enum.map(&Path.join(workspace, &1))
    |> Enum.find(&File.exists?/1)
  end

  def input_response_path(_workspace), do: nil

  defp prompt_context_from_workspace(workspace) do
    packet_path = blocker_packet_path(workspace)

    with true <- File.exists?(packet_path),
         input_path when is_binary(input_path) <- input_response_path(workspace),
         {:ok, packet_body} <- File.read(packet_path),
         {:ok, input_body} <- File.read(input_path) do
      """
      Operator input handoff context:

      - A previous attempt stopped at blocker_fingerprint=#{@fingerprint}.
      - This is a new attempt, not a live Codex thread resume.
      - Read and apply the durable blocker packet and operator input before doing any other ticket work.
      - Blocker packet path: #{packet_path}
      - Operator input path: #{input_path}

      Blocker packet:

      ```json
      #{packet_body}
      ```

      Operator input:

      ```text
      #{input_body}
      ```
      """
    else
      _ -> nil
    end
  end

  defp build_packet(blocked_entry, packet_workspace) do
    issue = Map.get(blocked_entry, :issue)

    %{
      "schema_version" => 1,
      "blocker_fingerprint" => @fingerprint,
      "issue" => %{
        "id" => issue_id(blocked_entry),
        "identifier" => issue_identifier(blocked_entry),
        "title" => issue_title(issue)
      },
      "session_id" => normalize_optional_string(Map.get(blocked_entry, :session_id)),
      "thread_id" => normalize_optional_string(extract_thread_id(blocked_entry)),
      "turn_id" => normalize_optional_string(extract_turn_id(blocked_entry)),
      "workspace_path" => workspace_path(blocked_entry),
      "handoff_packet_workspace_path" => packet_workspace,
      "blocker_packet_path" => blocker_packet_path(packet_workspace),
      "input_request_or_approval_summary" => request_summary(blocked_entry),
      "current_linear_state" => issue_state(issue),
      "blocked_at" => datetime_to_iso8601(Map.get(blocked_entry, :blocked_at)),
      "last_codex_event" => normalize_value(Map.get(blocked_entry, :last_codex_event)),
      "last_codex_timestamp" => datetime_to_iso8601(Map.get(blocked_entry, :last_codex_timestamp)),
      "next_elvis_action" => "Provide durable input in .symphony/operator-input-response.md or OPERATOR_INPUT.md, then move the issue back to Symphony Ready.",
      "re_release_rule" =>
        "Only return the issue to an active pickup state after durable input exists; the next pickup starts one new attempt and must read this packet and the input evidence before acting. This is not a live Codex thread resume."
    }
  end

  defp request_summary(blocked_entry) do
    last_message = Map.get(blocked_entry, :last_codex_message)

    %{
      "error" => Map.get(blocked_entry, :error),
      "event" => normalize_value(Map.get(blocked_entry, :last_codex_event)),
      "method" => extract_method(last_message),
      "payload" => extract_payload(last_message),
      "raw" => extract_raw(last_message)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp packet_workspace(%Issue{} = issue) do
    issue.identifier
    |> safe_identifier()
    |> workspace_under_root()
  end

  defp packet_workspace(blocked_entry) when is_map(blocked_entry) do
    configured_root = Config.settings!().workspace.root
    preferred = Map.get(blocked_entry, :workspace_path)

    cond do
      local_workspace_under_root?(preferred, configured_root) ->
        {:ok, preferred}

      true ->
        blocked_entry
        |> issue_identifier()
        |> safe_identifier()
        |> workspace_under_root()
    end
  end

  defp workspace_under_root(safe_id) do
    workspace = Path.join(Config.settings!().workspace.root, safe_id)

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(Config.settings!().workspace.root),
         true <- workspace_child_of_root?(canonical_workspace, canonical_root) do
      {:ok, canonical_workspace}
    else
      false -> {:error, {:workspace_outside_root, workspace}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp local_workspace_under_root?(path, root) when is_binary(path) and is_binary(root) do
    with {:ok, canonical_path} <- PathSafety.canonicalize(path),
         {:ok, canonical_root} <- PathSafety.canonicalize(root) do
      workspace_child_of_root?(canonical_path, canonical_root)
    else
      _ -> false
    end
  end

  defp local_workspace_under_root?(_path, _root), do: false

  defp workspace_child_of_root?(workspace, root) when is_binary(workspace) and is_binary(root) do
    workspace != root and String.starts_with?(workspace <> "/", root <> "/")
  end

  defp workspace_candidates(workspace, %Issue{} = issue) do
    [workspace, packet_workspace(issue)]
    |> Enum.map(fn
      {:ok, path} -> path
      path -> path
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp workspace_candidates(workspace, _issue), do: [workspace]

  defp issue_id(%{issue_id: issue_id}) when is_binary(issue_id), do: issue_id
  defp issue_id(%{issue: %Issue{id: issue_id}}) when is_binary(issue_id), do: issue_id
  defp issue_id(_blocked_entry), do: nil

  defp issue_identifier(%{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_identifier(%{issue: %Issue{identifier: identifier}}) when is_binary(identifier), do: identifier
  defp issue_identifier(%{issue_id: issue_id}) when is_binary(issue_id), do: issue_id
  defp issue_identifier(_blocked_entry), do: "issue"

  defp issue_state(%Issue{state: state}) when is_binary(state), do: state
  defp issue_state(_issue), do: nil

  defp issue_title(%Issue{title: title}) when is_binary(title), do: title
  defp issue_title(_issue), do: nil

  defp workspace_path(%{workspace_path: workspace_path}) when is_binary(workspace_path), do: workspace_path

  defp workspace_path(blocked_entry) do
    Path.join(Config.settings!().workspace.root, safe_identifier(issue_identifier(blocked_entry)))
  end

  defp extract_thread_id(blocked_entry) do
    extract_param(blocked_entry, ["threadId", :threadId, "thread_id", :thread_id])
  end

  defp extract_turn_id(blocked_entry) do
    extract_param(blocked_entry, ["turnId", :turnId, "turn_id", :turn_id])
  end

  defp extract_param(blocked_entry, keys) do
    last_message = Map.get(blocked_entry, :last_codex_message)
    payload = payload_from_message(last_message)
    params = map_get(payload, ["params", :params]) || %{}

    map_get(params, keys) || map_get(payload, keys)
  end

  defp extract_method(last_message) do
    last_message
    |> payload_from_message()
    |> map_get(["method", :method])
  end

  defp extract_payload(last_message) do
    last_message
    |> payload_from_message()
    |> normalize_value()
  end

  defp extract_raw(last_message) do
    map_get(last_message, [:raw, "raw"]) ||
      last_message
      |> map_get([:message, "message"])
      |> map_get([:raw, "raw"])
  end

  defp payload_from_message(last_message) when is_map(last_message) do
    nested_message = map_get(last_message, [:message, "message"])

    cond do
      is_map(nested_message) and is_map(map_get(nested_message, [:payload, "payload"])) ->
        map_get(nested_message, [:payload, "payload"])

      is_map(map_get(last_message, [:payload, "payload"])) ->
        map_get(last_message, [:payload, "payload"])

      is_map(nested_message) ->
        nested_message

      true ->
        last_message
    end
  end

  defp payload_from_message(_last_message), do: nil

  defp map_get(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp map_get(_map, _keys), do: nil

  defp safe_identifier(identifier) when is_binary(identifier) do
    String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp safe_identifier(_identifier), do: "issue"

  defp datetime_to_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp datetime_to_iso8601(_datetime), do: nil

  defp normalize_optional_string(value) when is_binary(value) and value != "", do: value
  defp normalize_optional_string(_value), do: nil

  defp blank_to_na(value) when is_binary(value) and value != "", do: value
  defp blank_to_na(_value), do: "n/a"

  defp normalize_value(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp normalize_value(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)
  defp normalize_value(%Date{} = date), do: Date.to_iso8601(date)
  defp normalize_value(%Time{} = time), do: Time.to_iso8601(time)
  defp normalize_value(%_{} = struct), do: struct |> Map.from_struct() |> normalize_value()

  defp normalize_value(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {normalize_key(key), normalize_value(value)} end)
  end

  defp normalize_value(values) when is_list(values), do: Enum.map(values, &normalize_value/1)
  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value), do: value

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)
end
