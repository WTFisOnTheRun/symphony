defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live operator dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, OperatorDashboard}

  @payload_poll_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_payload_poll()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:payload_poll, socket) do
    schedule_payload_poll()

    {:noreply, assign(socket, :payload, load_payload())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply, assign(socket, :payload, load_payload())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="dashboard-header">
        <div>
          <p class="eyebrow">Human operator surface</p>
          <h1 class="page-title">DTS Symphony Operator Dashboard</h1>
          <p class="page-copy">
            Runner health, task state, milestone progress, blockers, review paths, and next human actions. Raw JSON remains available only as a debug surface.
          </p>
        </div>

        <div class="status-stack">
          <span class={connection_badge_class(@payload.api.reachable)}>
            <span class="status-badge-dot"></span>
            <%= if @payload.api.reachable, do: "API reachable", else: "API unavailable" %>
          </span>
          <span class="status-subcopy">
            Generated <%= format_timestamp(@payload.generated_at) %>
          </span>
        </div>
      </header>

      <section class="debug-strip" aria-label="debug surfaces">
        <div>
          <strong>Operator view:</strong> this page. <strong>Debug view:</strong>
          <a href={@payload.debug.state_api_path}><%= @payload.debug.raw_api_label %></a>.
        </div>
        <button
          type="button"
          class="subtle-button"
          data-label="Copy API URL"
          data-copy={@payload.debug.state_api_url}
          onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
        >
          Copy API URL
        </button>
      </section>

      <%= if @payload.warnings != [] do %>
        <section class="warning-list" aria-label="dashboard warnings">
          <article :for={warning <- @payload.warnings} class={"warning warning-#{warning.level}"}>
            <strong><%= warning.title %></strong>
            <span><%= warning.detail || "No detail recorded." %></span>
          </article>
        </section>
      <% end %>

      <section class="metric-grid">
        <article class="metric-card">
          <p class="metric-label">Running</p>
          <p class="metric-value numeric"><%= @payload.counts.running %></p>
          <p class="metric-detail">Active runner sessions.</p>
        </article>

        <article class="metric-card">
          <p class="metric-label">Retrying</p>
          <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
          <p class="metric-detail">Waiting for retry window.</p>
        </article>

        <article class="metric-card">
          <p class="metric-label">Blocked</p>
          <p class="metric-value numeric"><%= @payload.counts.blocked %></p>
          <p class="metric-detail">Needs a human or workflow fix.</p>
        </article>

        <article class="metric-card">
          <p class="metric-label">In Review</p>
          <p class="metric-value numeric"><%= @payload.counts.in_review %></p>
          <p class="metric-detail">Evidence or REVIEW.md exists.</p>
        </article>

        <article class="metric-card">
          <p class="metric-label">Runtime Heartbeat</p>
          <p class="metric-value metric-value-small"><%= heartbeat_label(@payload.runtime) %></p>
          <p class="metric-detail">
            <%= if @payload.runtime.generated_at do %>
              <span class="numeric"><%= @payload.runtime.generated_at %></span>
            <% else %>
              Not readable
            <% end %>
          </p>
        </article>
      </section>

      <section class="section-panel">
        <div class="section-header">
          <div>
            <h2 class="section-title">Task Progress</h2>
            <p class="section-copy">
              Ledger-backed task state. Refreshes on LiveView events and polls files every <%= @payload.refresh.poll_interval_seconds %> seconds.
            </p>
          </div>
          <span class="pill">Recent tasks: <%= @payload.counts.recent %></span>
        </div>

        <%= if @payload.tasks == [] do %>
          <p class="empty-state">
            No active sessions or ledger-backed recent tasks were found. Check the raw API or runner status script for lower-level diagnostics.
          </p>
        <% else %>
          <div class="task-list">
            <article :for={task <- @payload.tasks} class={"task-row task-row-#{task.category}"}>
              <header class="task-row-header">
                <div class="issue-heading">
                  <a class="issue-id" href={task.linear_url} target="_blank" rel="noopener"><%= task.issue_identifier %></a>
                  <span class={category_badge_class(task.category)}><%= category_label(task.category) %></span>
                  <span class={state_badge_class(task.state)}><%= task.state || "recent" %></span>
                </div>
                <div class="task-meta numeric">
                  <span>Last event: <%= format_timestamp(task.last_event_at) %></span>
                  <span>Started: <%= format_timestamp(task.started_at) %></span>
                </div>
              </header>

              <div class="task-grid">
                <div class="task-summary">
                  <dl class="detail-list">
                    <div>
                      <dt>Current phase</dt>
                      <dd><%= task.current_phase || "Not recorded" %></dd>
                    </div>
                    <div>
                      <dt>Last message</dt>
                      <dd><%= task.last_message || task.last_event || "Not recorded" %></dd>
                    </div>
                    <div>
                      <dt>Next action</dt>
                      <dd><%= task.next_human_action %></dd>
                    </div>
                    <div :if={task.blocker_reason}>
                      <dt>Blocker</dt>
                      <dd><%= task.blocker_reason %></dd>
                    </div>
                    <div :if={task.blocker_fingerprint}>
                      <dt>Blocker fingerprint</dt>
                      <dd class="mono"><%= task.blocker_fingerprint %></dd>
                    </div>
                  </dl>

                  <div class="path-list">
                    <.path_row label="Workspace" path={task.workspace_path} />
                    <.path_row label="Review path" path={task.review_path} />
                    <.path_row label="Latest output" path={task.latest_output_path} />
                    <.path_row :for={path <- task.evidence_paths} label="Evidence path" path={path} />
                  </div>
                </div>

                <div class="milestone-panel">
                  <h3 class="subsection-title">Milestones</h3>
                  <ol class="milestone-list">
                    <li :for={milestone <- task.milestones} class={milestone_class(milestone.state)}>
                      <span class="milestone-dot" aria-hidden="true"></span>
                      <span class="milestone-name"><%= milestone.name %></span>
                      <span class="milestone-state"><%= milestone.state %></span>
                      <span class="milestone-time numeric"><%= format_timestamp(milestone.at) %></span>
                    </li>
                  </ol>
                </div>
              </div>

              <footer class="task-footer">
                <span>Sources: <%= Enum.join(task.sources, ", ") %></span>
                <span :if={task.session_id}>Session: <span class="mono"><%= short_id(task.session_id) %></span></span>
                <span :if={task.tokens.total_tokens}>Tokens: <span class="numeric"><%= format_int(task.tokens.total_tokens) %></span></span>
              </footer>
            </article>
          </div>
        <% end %>
      </section>

      <section class="section-panel section-panel-compact">
        <div class="section-header">
          <div>
            <h2 class="section-title">Data Sources</h2>
            <p class="section-copy">
              Runtime health comes from the state API and runtime-state file. Task phase, blocker, evidence, and milestone detail come from watchdog ledgers.
            </p>
          </div>
        </div>
        <div class="source-grid">
          <div>
            <span class="source-label">State API</span>
            <span><%= if @payload.api.reachable, do: "reachable", else: @payload.api.error_code || "unavailable" %></span>
          </div>
          <div>
            <span class="source-label">Runtime file</span>
            <span><%= @payload.runtime.logs_root %></span>
          </div>
          <div>
            <span class="source-label">Ledgers read</span>
            <span class="numeric"><%= @payload.runtime.ledger_count %></span>
          </div>
          <div>
            <span class="source-label">Stale threshold</span>
            <span class="numeric"><%= @payload.refresh.stale_after_seconds %> seconds</span>
          </div>
        </div>
      </section>
    </section>
    """
  end

  attr(:label, :string, required: true)
  attr(:path, :string, default: nil)

  defp path_row(assigns) do
    ~H"""
    <div :if={@path} class="path-row">
      <span class="path-label"><%= @label %></span>
      <code title={@path}><%= @path %></code>
      <button
        type="button"
        class="path-copy"
        data-label="Copy"
        data-copy={@path}
        onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
      >
        Copy
      </button>
    </div>
    """
  end

  defp load_payload do
    OperatorDashboard.payload(orchestrator(), snapshot_timeout_ms(),
      dts_logs_root: Endpoint.config(:dts_logs_root),
      fixture_ledger_root: Endpoint.config(:fixture_ledger_root)
    )
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp schedule_payload_poll do
    Process.send_after(self(), :payload_poll, @payload_poll_ms)
  end

  defp connection_badge_class(true), do: "status-badge status-badge-live"
  defp connection_badge_class(_reachable), do: "status-badge status-badge-offline"

  defp heartbeat_label(%{available: false}), do: "Missing"
  defp heartbeat_label(%{stale?: true}), do: "Stale"
  defp heartbeat_label(%{dashboard_reachable: false}), do: "API down"
  defp heartbeat_label(_runtime), do: "Fresh"

  defp category_label("in-review"), do: "in review"
  defp category_label(category), do: category

  defp category_badge_class(category), do: "state-badge category-#{category}"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["needs", "review"]) -> "#{base} state-badge-review"
      String.contains?(normalized, ["retry", "queued", "pending"]) -> "#{base} state-badge-warning"
      String.contains?(normalized, ["done", "complete", "terminal", "canceled", "superseded"]) -> "#{base} state-badge-muted"
      String.contains?(normalized, ["progress", "running", "active", "ready"]) -> "#{base} state-badge-active"
      true -> base
    end
  end

  defp milestone_class(state), do: "milestone milestone-#{state || "pending"}"

  defp format_timestamp(nil), do: "n/a"
  defp format_timestamp(""), do: "n/a"

  defp format_timestamp(timestamp) when is_binary(timestamp) do
    timestamp
  end

  defp format_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp format_timestamp(timestamp), do: to_string(timestamp)

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp short_id(id) when is_binary(id) and byte_size(id) > 16 do
    String.slice(id, 0, 8) <> "..." <> String.slice(id, -6, 6)
  end

  defp short_id(id), do: id || "n/a"
end
