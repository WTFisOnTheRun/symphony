defmodule SymphonyElixir.TestSupport do
  @workflow_prompt "You are an agent for this repository."
  @original_path System.get_env("PATH") || ""

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case, async: false
      import ExUnit.CaptureLog

      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Codex.AppServer
      alias SymphonyElixir.Config
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [
          write_workflow_file!: 1,
          write_workflow_file!: 2,
          restore_env: 2,
          stop_default_http_server: 0,
          bash_command_path: 1,
          bash_original_path_executable!: 1,
          create_test_directory_link!: 2,
          install_fake_ssh!: 2,
          install_fake_ssh!: 3,
          original_path_executable!: 1,
          path_separator: 0,
          prepend_path!: 1,
          windows?: 0
        ]

      setup do
        runtime_lock = {SymphonyElixir.TestSupport, :runtime_state}
        :global.set_lock(runtime_lock, [node()], :infinity)
        on_exit(fn -> :global.del_lock(runtime_lock, [node()]) end)

        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-workflow-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        workflow_file = Path.join(workflow_root, "WORKFLOW.md")
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)
        if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()
        stop_default_http_server()

        on_exit(fn ->
          Application.delete_env(:symphony_elixir, :workflow_file_path)
          Application.delete_env(:symphony_elixir, :server_port_override)
          Application.delete_env(:symphony_elixir, :memory_tracker_issues)
          Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  def write_workflow_file!(path, overrides \\ []) do
    workflow = workflow_content(overrides)
    File.write!(path, workflow)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def windows?, do: match?({:win32, _}, :os.type())

  def path_separator do
    if windows?(), do: ";", else: ":"
  end

  def prepend_path!(path) when is_binary(path) do
    System.put_env("PATH", path <> path_separator() <> (System.get_env("PATH") || ""))
  end

  def ensure_test_shell_path! do
    if windows?() do
      case git_bash_bin_path() do
        nil -> :ok
        path -> prepend_path!(path)
      end
    end

    :ok
  end

  def bash_command_path(path) when is_binary(path) do
    expanded = Path.expand(path)

    case Regex.run(~r/^([A-Za-z]):[\\\/](.*)$/, expanded, capture: :all_but_first) do
      [drive, rest] ->
        "/" <> String.downcase(drive) <> "/" <> String.replace(rest, "\\", "/")

      _ ->
        String.replace(expanded, "\\", "/")
    end
  end

  def original_path_executable!(name) when is_binary(name) do
    case original_path_executable(name) do
      nil -> raise "could not find #{name} on original PATH"
      executable -> executable
    end
  end

  def bash_original_path_executable!(name) when is_binary(name) do
    name
    |> original_path_executable!()
    |> bash_command_path()
    |> shell_quote()
  end

  def create_test_directory_link!(target, link) when is_binary(target) and is_binary(link) do
    case File.ln_s(target, link) do
      :ok -> :ok
      {:error, :eperm} -> maybe_create_windows_junction!(target, link)
      {:error, reason} -> raise "failed to create symlink fixture: #{inspect(reason)}"
    end
  end

  def install_fake_ssh!(test_root, trace_file, script \\ nil) do
    fake_bin_dir = Path.join(test_root, "bin")

    install_fake_ssh_executable!(
      fake_bin_dir,
      script ||
        """
        #!/bin/sh
        printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
        exit 0
        """
    )

    prepend_path!(fake_bin_dir)
  end

  defp install_fake_ssh_executable!(bin_dir, script) when is_binary(bin_dir) and is_binary(script) do
    File.mkdir_p!(bin_dir)

    if windows?() do
      script_path = Path.join(bin_dir, "ssh.sh")
      launcher_path = Path.join(bin_dir, "ssh.bat")

      File.write!(script_path, normalize_script_newlines(script))

      bash_executable =
        case git_bash_bin_path() do
          nil -> "bash"
          path -> Path.join(path, "bash.exe")
        end

      File.write!(launcher_path, """
      @echo off
      set MSYS2_ARG_CONV_EXCL=*
      set MSYS_NO_PATHCONV=1
      "#{bash_executable}" "%~dp0ssh.sh" %*
      exit /b %ERRORLEVEL%
      """)

      launcher_path
    else
      executable_path = Path.join(bin_dir, "ssh")
      File.write!(executable_path, normalize_script_newlines(script))
      File.chmod!(executable_path, 0o755)
      executable_path
    end
  end

  def install_fake_executable!(bin_dir, name, script)
      when is_binary(bin_dir) and is_binary(name) and is_binary(script) do
    File.mkdir_p!(bin_dir)

    if windows?() do
      script_path = Path.join(bin_dir, "#{name}.sh")
      implementation_path = Path.join(bin_dir, "#{name}.impl.sh")
      launcher_path = Path.join(bin_dir, "#{name}.bat")

      File.write!(implementation_path, normalize_script_newlines(script))

      File.write!(script_path, """
      #!/bin/sh
      if [ "${SYMP_FAKE_ARGV+x}" = "x" ]; then
        eval "set -- $SYMP_FAKE_ARGV"
      fi

      . "$(dirname "$0")/#{name}.impl.sh"
      """)

      bash_executable =
        case git_bash_bin_path() do
          nil -> "bash"
          path -> Path.join(path, "bash.exe")
        end

      File.write!(launcher_path, """
      @echo off
      set MSYS2_ARG_CONV_EXCL=*
      set MSYS_NO_PATHCONV=1
      set "SYMP_FAKE_ARGV=%*"
      "#{bash_executable}" "%~dp0#{name}.sh"
      exit /b %ERRORLEVEL%
      """)

      launcher_path
    else
      executable_path = Path.join(bin_dir, name)
      File.write!(executable_path, normalize_script_newlines(script))
      File.chmod!(executable_path, 0o755)
      executable_path
    end
  end

  def stop_default_http_server do
    case Enum.find(Supervisor.which_children(SymphonyElixir.Supervisor), fn
           {SymphonyElixir.HttpServer, _pid, _type, _modules} -> true
           _child -> false
         end) do
      {SymphonyElixir.HttpServer, pid, _type, _modules} when is_pid(pid) ->
        :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.HttpServer)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp git_bash_bin_path do
    [
      "C:/Program Files/Git/bin",
      "C:/Program Files/Git/usr/bin",
      "C:/Program Files (x86)/Git/bin",
      "C:/Program Files (x86)/Git/usr/bin"
    ]
    |> Enum.find(&File.exists?/1)
  end

  defp original_path_executable(name) do
    @original_path
    |> String.split(path_separator(), trim: true)
    |> Enum.flat_map(fn dir -> Enum.map(executable_names(name), &Path.join(dir, &1)) end)
    |> Enum.find(&File.exists?/1)
  end

  defp executable_names(name) do
    cond do
      not windows?() ->
        [name]

      Path.extname(name) != "" ->
        [name]

      true ->
        (System.get_env("PATHEXT") || ".COM;.EXE;.BAT;.CMD")
        |> String.split(";", trim: true)
        |> Enum.map(&(name <> &1))
    end
  end

  defp shell_quote(path) do
    "'" <> String.replace(path, "'", "'\\''") <> "'"
  end

  defp create_windows_junction!(target, link) do
    case System.cmd(
           "cmd",
           ["/c", "mklink", "/J", windows_cmd_path(link), windows_cmd_path(target)],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {output, status} ->
        raise "failed to create junction fixture: status=#{status} output=#{inspect(output)}"
    end
  end

  defp maybe_create_windows_junction!(target, link) do
    if windows?() do
      create_windows_junction!(target, link)
    else
      raise "failed to create symlink fixture: :eperm"
    end
  end

  defp windows_cmd_path(path) do
    path
    |> Path.expand()
    |> String.replace("/", "\\")
  end

  defp normalize_script_newlines(script) when is_binary(script) do
    String.replace(script, "\r\n", "\n")
  end

  defp workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: "token",
          tracker_project_slug: "project",
          tracker_assignee: nil,
          tracker_active_states: ["Todo", "In Progress"],
          tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          tracker_operator_input_handoff_state: "In Review",
          poll_interval_ms: 30_000,
          workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
          worker_ssh_hosts: [],
          worker_max_concurrent_agents_per_host: nil,
          max_concurrent_agents: 10,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          max_concurrent_agents_by_state: %{},
          codex_command: "codex app-server",
          codex_approval_policy: %{reject: %{sandbox_approval: true, rules: true, mcp_elicitations: true}},
          codex_thread_sandbox: "workspace-write",
          codex_turn_sandbox_policy: nil,
          codex_turn_timeout_ms: 3_600_000,
          codex_read_timeout_ms: 5_000,
          codex_stall_timeout_ms: 300_000,
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          server_port: nil,
          server_host: nil,
          prompt: @workflow_prompt
        ],
        overrides
      )

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_endpoint = Keyword.get(config, :tracker_endpoint)
    tracker_api_token = Keyword.get(config, :tracker_api_token)
    tracker_project_slug = Keyword.get(config, :tracker_project_slug)
    tracker_assignee = Keyword.get(config, :tracker_assignee)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    tracker_operator_input_handoff_state = Keyword.get(config, :tracker_operator_input_handoff_state)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)
    worker_max_concurrent_agents_per_host = Keyword.get(config, :worker_max_concurrent_agents_per_host)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    codex_command = Keyword.get(config, :codex_command)
    codex_approval_policy = Keyword.get(config, :codex_approval_policy)
    codex_thread_sandbox = Keyword.get(config, :codex_thread_sandbox)
    codex_turn_sandbox_policy = Keyword.get(config, :codex_turn_sandbox_policy)
    codex_turn_timeout_ms = Keyword.get(config, :codex_turn_timeout_ms)
    codex_read_timeout_ms = Keyword.get(config, :codex_read_timeout_ms)
    codex_stall_timeout_ms = Keyword.get(config, :codex_stall_timeout_ms)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    prompt = Keyword.get(config, :prompt)

    sections =
      [
        "---",
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  endpoint: #{yaml_value(tracker_endpoint)}",
        "  api_key: #{yaml_value(tracker_api_token)}",
        "  project_slug: #{yaml_value(tracker_project_slug)}",
        "  assignee: #{yaml_value(tracker_assignee)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "  operator_input_handoff_state: #{yaml_value(tracker_operator_input_handoff_state)}",
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        worker_yaml(worker_ssh_hosts, worker_max_concurrent_agents_per_host),
        "agent:",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        "codex:",
        "  command: #{yaml_value(codex_command)}",
        "  approval_policy: #{yaml_value(codex_approval_policy)}",
        "  thread_sandbox: #{yaml_value(codex_thread_sandbox)}",
        "  turn_sandbox_policy: #{yaml_value(codex_turn_sandbox_policy)}",
        "  turn_timeout_ms: #{yaml_value(codex_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(codex_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(codex_stall_timeout_ms)}",
        hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, hook_timeout_ms),
        observability_yaml(observability_enabled, observability_refresh_ms, observability_render_interval_ms),
        server_yaml(server_port, server_host),
        "---",
        prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp yaml_value(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"" <> escaped <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms), do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host)
       when ssh_hosts in [nil, []] and is_nil(max_concurrent_agents_per_host),
       do: nil

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host) do
    [
      "worker:",
      ssh_hosts not in [nil, []] && "  ssh_hosts: #{yaml_value(ssh_hosts)}",
      !is_nil(max_concurrent_agents_per_host) &&
        "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp observability_yaml(enabled, refresh_ms, render_interval_ms) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}"
    ]
    |> Enum.join("\n")
  end

  defp server_yaml(nil, nil), do: nil

  defp server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end
end
