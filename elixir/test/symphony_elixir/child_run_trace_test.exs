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
      |> ChildRunTrace.denial_ledger(:write_file, "C:\\unauthorized\\target.txt",
        denial_reason: :tool_not_in_effective_read_only_grant,
        budget_context: %{
          budget_source: :synthetic_fixture,
          raw_budget_source: "synthetic_fixture",
          remaining_warn_fuse_budget: 520_000
        }
      )
      |> ChildRunTrace.to_jsonl()

    assert String.contains?(jsonl, "\"event\":\"tool_denied\"")
    assert String.contains?(jsonl, "\"event\":\"stop_close\"")
    assert String.contains?(jsonl, "\"proof_only\":true")
    assert String.contains?(jsonl, "\"terminal_blocker\":true")
    assert String.contains?(jsonl, "\"budget_source\":\"synthetic_fixture\"")
    assert String.contains?(jsonl, "\"remaining_warn_fuse_budget\":520000")
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

  test "budget fields tolerate raw reserve values and malformed budget context" do
    integer_budget_event =
      contract()
      |> ChildRunTrace.budget_denial_ledger(@path, 500_000)
      |> Enum.find(&(&1.event == :budget_threshold))

    assert integer_budget_event.attrs.remaining_warn_fuse_budget == 500_000
    assert integer_budget_event.attrs.reason == :parent_synthesis_reserve_breach
    assert integer_budget_event.attrs.budget_source == nil

    malformed_budget_event =
      contract()
      |> ChildRunTrace.budget_denial_ledger(@path, :unknown)
      |> Enum.find(&(&1.event == :budget_threshold))

    assert malformed_budget_event.attrs.remaining_warn_fuse_budget == nil
    assert malformed_budget_event.attrs.reason == :parent_synthesis_reserve_breach
    assert malformed_budget_event.attrs.budget_source == nil

    valid_event =
      contract()
      |> ChildRunTrace.valid_run_ledger(@path, budget_context: :unknown)
      |> Enum.find(&(&1.event == :budget_threshold))

    refute Map.has_key?(valid_event.attrs, :remaining_warn_fuse_budget)
    refute Map.has_key?(valid_event.attrs, :budget_source)
  end
end
