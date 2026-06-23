defmodule MiniAgent.CLI do
  @moduledoc "Escript entry point. Parses CLI args and drives the agent loop."

  alias MiniAgent.Checkpoint

  @doc "Entry point for escript. Accepts optional --auto / --mode / --stream / --parallel / --resume / --list / --delete flags and a task string."
  @spec main(list(String.t())) :: :ok
  def main(args \\ []) do
    {opts, rest, _} =
      OptionParser.parse(args,
        switches: [
          mode: :string,
          auto: :boolean,
          stream: :boolean,
          parallel: :boolean,
          resume: :string,
          list: :boolean,
          delete: :string,
          workspace: :string
        ],
        aliases: [
          m: :mode,
          a: :auto,
          s: :stream,
          p: :parallel,
          r: :resume,
          l: :list,
          w: :workspace
        ]
      )

    cond do
      opts[:list] ->
        print_sessions()

      opts[:delete] ->
        Checkpoint.delete(opts[:delete])
        IO.puts("Deleted session #{opts[:delete]}")

      opts[:resume] ->
        apply_workspace_override(opts)
        run_resume(opts[:resume], opts)

      true ->
        task =
          case rest do
            [] -> prompt_task()
            parts -> Enum.join(parts, " ")
          end

        if task == "" do
          print_usage()
        else
          mode = parse_mode(opts)
          apply_workspace_override(opts)
          IO.puts("\nMini Agent starting (mode: #{mode})")
          IO.puts("Task: #{task}\n")
          execute(task, mode, opts)
        end
    end
  end

  @spec parse_mode(keyword()) :: MiniAgent.Permission.mode()
  defp parse_mode(opts) do
    cond do
      opts[:auto] -> :auto
      opts[:mode] == "readonly" -> :readonly
      opts[:mode] == "auto" -> :auto
      true -> :ask
    end
  end

  # Override workspace at runtime so the escript can target any project directory
  # without recompiling. Note: Application.put_env is node-global; safe for the
  # single-agent CLI use case (one agent per OS process).
  @spec apply_workspace_override(keyword()) :: :ok
  defp apply_workspace_override(opts) do
    case opts[:workspace] do
      nil -> :ok
      path -> Application.put_env(:mini_agent, :workspace, Path.expand(path))
    end
  end

  @spec execute(String.t(), MiniAgent.Permission.mode(), keyword()) :: :ok
  defp execute(task, mode, opts) do
    agent_opts = [mode: mode, autosave: true]

    cond do
      opts[:parallel] -> run_orchestrator(task, mode)
      opts[:stream] -> run_streaming(task, agent_opts)
      true -> run_default(task, agent_opts)
    end
  end

  @spec run_orchestrator(String.t(), MiniAgent.Permission.mode()) :: :ok
  defp run_orchestrator(task, mode) do
    IO.puts("Orchestrator mode: decomposing into sub-agents...\n")
    output = MiniAgent.Orchestrator.run(task, mode: mode)
    IO.puts("\nDONE\n#{output}")
    :ok
  end

  @spec run_streaming(String.t(), keyword()) :: :ok
  defp run_streaming(task, agent_opts) do
    IO.puts("Streaming enabled\n")
    {:ok, pid} = MiniAgent.start_link(task, Keyword.put(agent_opts, :stream, true))
    sid = get_session_id(pid)
    IO.puts("Session: #{sid}  (resume with: --resume #{sid})\n")
    output = MiniAgent.run(pid)
    IO.puts("\nDONE\n#{output}")
    :ok
  end

  @spec run_default(String.t(), keyword()) :: :ok
  defp run_default(task, agent_opts) do
    {:ok, pid} = MiniAgent.start_link(task, agent_opts)
    sid = get_session_id(pid)
    IO.puts("Session: #{sid}  (resume with: --resume #{sid})\n")
    output = MiniAgent.run(pid)
    IO.puts("\nDONE\n#{output}")
    :ok
  end

  @spec run_resume(MiniAgent.Checkpoint.session_id(), keyword()) :: :ok
  defp run_resume(session_id, opts) do
    case MiniAgent.resume(session_id, autosave: true, stream: opts[:stream] || false) do
      {:ok, pid} ->
        state = :sys.get_state(pid)

        if state.done do
          IO.puts("Session #{session_id} was already completed.")
          IO.puts("\nDONE\n#{state.output}")
        else
          IO.puts("Resuming session #{session_id} from iteration #{state.iterations}...\n")
          output = MiniAgent.run(pid)
          IO.puts("\nDONE\n#{output}")
        end

      {:error, reason} ->
        IO.puts("Error resuming checkpoint: #{reason}")
    end

    :ok
  end

  @spec print_sessions() :: :ok
  defp print_sessions do
    case Checkpoint.list() do
      [] ->
        IO.puts("(no checkpoints saved yet)")

      sessions ->
        IO.puts("\nSaved sessions:\n")
        Enum.each(sessions, &print_session_entry/1)
    end

    :ok
  end

  @spec print_session_entry(Checkpoint.summary()) :: :ok
  defp print_session_entry(s) do
    status = if s.done, do: "done", else: "in progress"
    IO.puts("  #{s.session_id}")
    IO.puts("    #{status} - iteration #{s.iterations} - #{s.tokens} tokens - #{s.saved_at}")
    IO.puts("    task: #{s.task}")
    IO.puts("")
  end

  @spec get_session_id(pid()) :: String.t()
  defp get_session_id(pid) do
    case :sys.get_state(pid) do
      %{session_id: sid} when is_binary(sid) -> sid
      _ -> "(unknown)"
    end
  end

  @spec prompt_task() :: String.t()
  defp prompt_task do
    IO.gets("Enter task for agent: ") |> to_string() |> String.trim()
  end

  @spec print_usage() :: :ok
  defp print_usage do
    IO.puts("""
    Mini Agent - usage:

      ./mini_agent "your task"                        run new task
      ./mini_agent --mode readonly "task"             readonly mode
      ./mini_agent --mode auto "task"                 auto-approve all tools
      ./mini_agent --stream "task"                    streaming output
      ./mini_agent --parallel "task"                  orchestrator / sub-agents
      ./mini_agent --workspace /path/to/project "task" override workspace root
      ./mini_agent --list                             list saved checkpoints
      ./mini_agent --resume <id>                      resume an in-progress session
      ./mini_agent --delete <id>                      delete a checkpoint
    """)

    :ok
  end
end
