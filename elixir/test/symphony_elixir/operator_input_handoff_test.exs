defmodule SymphonyElixir.OperatorInputHandoffTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.OperatorInputHandoff

  test "persists blocker packets and renders prompt context after durable input" do
    test_root = unique_test_root("operator-input-handoff")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-INPUT")

      File.mkdir_p!(workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-uuid",
        identifier: "MT-INPUT",
        title: "Need input",
        state: "Symphony Ready"
      }

      blocked_entry = %{
        issue: issue,
        workspace_path: workspace,
        session_id: "session-1",
        blocked_at: ~U[2026-06-02 01:02:03Z],
        last_codex_event: :operator_input_required,
        last_codex_timestamp: ~U[2026-06-02 01:03:04Z],
        last_codex_message: %{
          message: %{
            payload: %{
              "method" => "item/mcp_elicitation/request",
              "params" => %{
                "threadId" => "thread-1",
                "turnId" => "turn-1",
                "payload" => %{
                  atom_key: [
                    ~U[2026-06-02 01:04:05Z],
                    ~N[2026-06-02 01:05:06],
                    ~D[2026-06-02],
                    ~T[01:06:07],
                    %Issue{id: "nested-issue", identifier: "MT-NESTED"},
                    :approval_required
                  ]
                }
              }
            }
          }
        }
      }

      assert OperatorInputHandoff.fingerprint() == "operator_input_required"
      assert {:ok, packet} = OperatorInputHandoff.persist_blocker(blocked_entry)

      assert packet["issue"]["id"] == "issue-uuid"
      assert packet["issue"]["identifier"] == "MT-INPUT"
      assert packet["issue"]["title"] == "Need input"
      assert packet["current_linear_state"] == "Symphony Ready"
      assert packet["session_id"] == "session-1"
      assert packet["thread_id"] == "thread-1"
      assert packet["turn_id"] == "turn-1"
      assert packet["last_codex_event"] == "operator_input_required"
      assert packet["last_codex_timestamp"] == "2026-06-02T01:03:04Z"

      packet_workspace = packet["handoff_packet_workspace_path"]

      assert File.exists?(OperatorInputHandoff.blocker_packet_path(packet_workspace))
      assert OperatorInputHandoff.unresolved_blocker?(issue)

      input_path = Path.join(packet_workspace, "OPERATOR_INPUT.md")
      File.write!(input_path, "Use the approved value.\n")

      refute OperatorInputHandoff.unresolved_blocker?(issue)
      assert OperatorInputHandoff.input_response_path(packet_workspace) == input_path

      prompt = OperatorInputHandoff.prompt_context(packet_workspace)
      assert prompt =~ "Operator input handoff context"
      assert prompt =~ "operator-input-blocker.json"
      assert prompt =~ "Use the approved value."

      prompt_with_issue = OperatorInputHandoff.prompt_context(workspace, issue)
      assert prompt_with_issue =~ "thread-1"

      assert {:ok, issue_id_packet} =
               OperatorInputHandoff.persist_blocker(%{
                 issue_id: "issue-no-title",
                 last_codex_message: "not a map"
               })

      assert issue_id_packet["issue"]["id"] == "issue-no-title"
      assert issue_id_packet["issue"]["identifier"] == "issue-no-title"
      assert issue_id_packet["issue"]["title"] == nil
      assert issue_id_packet["blocked_at"] == nil
      assert issue_id_packet["session_id"] == nil
    after
      File.rm_rf(test_root)
    end
  end

  test "empty or invalid prompt inputs are ignored" do
    workspace = unique_test_root("operator-input-empty")

    assert OperatorInputHandoff.prompt_context(workspace) == ""
    assert OperatorInputHandoff.prompt_context(123, nil) == ""
    assert OperatorInputHandoff.input_response_path(123) == nil
    refute OperatorInputHandoff.unresolved_blocker?(%{})

    File.rm_rf(workspace)
  end

  test "comment body reports failed packet writes and direct payload requests" do
    blocked_entry = %{
      issue: %Issue{id: "issue-direct", identifier: "MT-DIRECT"},
      workspace_path: "C:/workspaces/MT-DIRECT",
      last_codex_event: :approval_required,
      last_codex_message: %{
        payload: %{
          method: "item/commandExecution/requestApproval",
          params: %{thread_id: "thread-direct", turn_id: "turn-direct"},
          raw: "direct raw"
        }
      }
    }

    body = OperatorInputHandoff.comment_body(blocked_entry, {:error, :eperm}, "In Review")

    assert body =~ "durable_packet: packet write failed: :eperm"
    assert body =~ "current_linear_state: "
    assert body =~ "session_id: n/a"
    assert body =~ "thread_id: thread-direct"
    assert body =~ "turn_id: turn-direct"
    assert body =~ "item/commandExecution/requestApproval"
  end

  test "comment body falls back when issue identifiers and structured payloads are absent" do
    body =
      OperatorInputHandoff.comment_body(
        %{last_codex_message: %{raw: "raw only"}},
        {:ok, %{"packet_path" => "packet.json"}},
        "In Review"
      )

    assert body =~ "issue_id: "
    assert body =~ "issue_identifier: issue"
    assert body =~ "durable_packet: packet.json"
    assert body =~ "raw only"

    nested_body =
      OperatorInputHandoff.comment_body(
        %{issue_id: "issue-nested", last_codex_message: %{message: %{method: "nested-method", raw: "nested raw"}}},
        {:ok, %{"packet_path" => "packet.json"}},
        "In Review"
      )

    assert nested_body =~ "issue_id: issue-nested"
    assert nested_body =~ "issue_identifier: issue-nested"
    assert nested_body =~ "nested-method"

    non_map_body =
      OperatorInputHandoff.comment_body(
        %{last_codex_message: "not a map"},
        {:ok, %{"packet_path" => "packet.json"}},
        "In Review"
      )

    assert non_map_body =~ "issue_identifier: issue"
  end

  test "canonicalization failures suppress unresolved blocker checks" do
    long_segment = String.duplicate("a", 300)
    workspace_root = yaml_path(Path.join(System.tmp_dir!(), long_segment))
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    issue = %Issue{identifier: "MT-LONG"}

    refute OperatorInputHandoff.unresolved_blocker?(issue)

    case OperatorInputHandoff.persist_blocker(%{identifier: "MT-LONG"}) do
      {:error, _reason} ->
        :ok

      {:ok, _packet} ->
        assert match?({:win32, _}, :os.type())
    end
  end

  test "symlink escapes are rejected when the platform can create symlinks" do
    test_root = unique_test_root("operator-input-symlink")
    workspace_root = Path.join(test_root, "workspaces")
    outside_root = Path.join(test_root, "outside")
    escaped_workspace = Path.join(workspace_root, "MT-ESCAPE")

    try do
      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_root)
      create_test_directory_link!(outside_root, escaped_workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{identifier: "MT-ESCAPE"}

      refute OperatorInputHandoff.unresolved_blocker?(issue)
      assert {:error, {:workspace_outside_root, _path}} = OperatorInputHandoff.persist_blocker(%{identifier: "MT-ESCAPE"})
    after
      File.rm_rf(test_root)
    end
  end

  defp unique_test_root(name) do
    System.tmp_dir!()
    |> Path.join("#{name}-#{System.unique_integer([:positive])}")
    |> yaml_path()
  end

  defp yaml_path(path), do: String.replace(path, "\\", "/")
end
