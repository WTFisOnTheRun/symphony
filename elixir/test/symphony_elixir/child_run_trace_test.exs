defmodule SymphonyElixir.ChildRunTraceTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ChildRunContract
  alias SymphonyElixir.ChildRunTrace

  @path "synthetic://dts39/context.md"

  defp contract do
    {:ok, contract} =
      ChildRunContract.build(%{
        issue_identifier: "DTS-39",
        goal: "trace proof",
        bounded_question: "Return the trace event proof.",
        read_targets: [@path],
        source_refs: ["DTS-39 Goal Contract"],
        constraints: ["proof-only"],
        parent_revision: "r1"
      })

    contract
  end

  test "required event families include control, budget, stale, and STOP proof" do
    assert ChildRunTrace.required_event_types() == [
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

    refute ChildRunTrace.covers_required_events?([
             ChildRunTrace.event(:child_start),
             ChildRunTrace.event(:parent_synthesis)
           ])
  end

  test "combined valid and denial ledgers cover every required event family" do
    stale_rejection =
      ChildRunTrace.event(:stale_rejection, %{
        state: :rejected,
        reason: :parent_revision_changed
      })

    events =
      ChildRunTrace.valid_run_ledger(contract(), @path) ++
        ChildRunTrace.denial_ledger(contract(), :write_file, "C:\\unauthorized\\target.txt") ++
        [stale_rejection]

    assert ChildRunTrace.covers_required_events?(events)

    assert Enum.any?(events, &(&1.event == :child_start))
    assert Enum.any?(events, &(&1.event == :effective_tool_grant))
    assert Enum.any?(events, &(&1.event == :tool_call_attempt))
    assert Enum.any?(events, &(&1.event == :tool_denied))
    assert Enum.any?(events, &(&1.event == :path_check))
    assert Enum.any?(events, &(&1.event == :budget_threshold))
    assert Enum.any?(events, &(&1.event == :child_terminal_state))
    assert Enum.any?(events, &(&1.event == :parent_synthesis))
    assert Enum.any?(events, &(&1.event == :stale_rejection))
    assert Enum.any?(events, &(&1.event == :stop_close))
  end

  test "jsonl encoding emits bounded diagnostic events without transcript content" do
    jsonl =
      contract()
      |> ChildRunTrace.denial_ledger(:write_file, "C:\\unauthorized\\target.txt")
      |> ChildRunTrace.to_jsonl()

    assert String.contains?(jsonl, "\"event\":\"tool_denied\"")
    assert String.contains?(jsonl, "\"event\":\"stop_close\"")
    assert String.contains?(jsonl, "\"proof_only\":true")
    refute String.contains?(jsonl, "raw_transcript")
    refute String.contains?(jsonl, "parent_history")
  end

  test "jsonl encoding handles primitive and nested diagnostic values" do
    event =
      ChildRunTrace.event(:tool_denied, %{
        binary: "quoted \"value\" with slash \\ and newline\n",
        integer: 12,
        float: 12.5,
        true_value: true,
        false_value: false,
        nil_value: nil,
        list_value: [:read_file, "plain", 3]
      })

    jsonl = ChildRunTrace.to_jsonl([event])

    assert String.ends_with?(jsonl, "\n")
    assert String.contains?(jsonl, "\"event\":\"tool_denied\"")
    assert String.contains?(jsonl, "\"integer\":12")
    assert String.contains?(jsonl, "\"float\":12.5")
    assert String.contains?(jsonl, "\"true_value\":true")
    assert String.contains?(jsonl, "\"false_value\":false")
    assert String.contains?(jsonl, "\"nil_value\":null")
    assert String.contains?(jsonl, "\"list_value\":[\"read_file\",\"plain\",3]")
    assert String.contains?(jsonl, "quoted \\\"value\\\" with slash \\\\ and newline\\n")
  end
end
