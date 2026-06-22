defmodule MiniAgent.CLI do
  @moduledoc "Escript entry point. Parses CLI args and drives the agent loop."

  @doc "Entry point for escript. Accepts optional --auto / --mode / --stream / --parallel flags and a task string."
  @spec main(list(String.t())) :: :ok
  def main(args \\ []) do
    {opts, rest, _} =
      OptionParser.parse(args,
        switches: [mode: :string, auto: :boolean, stream: :boolean, parallel: :boolean],
        aliases: [m: :mode, a: :auto, s: :stream, p: :parallel]
      )

    mode = parse_mode(opts)

    task =
      case rest do
        [] -> prompt_task()
        parts -> Enum.join(parts, " ")
      end

    IO.puts("\nMini Agent starting (mode: #{mode})")
    IO.puts("Task: #{task}\n")

    execute(task, mode, opts)
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

  @spec execute(String.t(), MiniAgent.Permission.mode(), keyword()) :: :ok
  defp execute(task, mode, opts) do
    cond do
      opts[:parallel] -> run_orchestrator(task, mode)
      opts[:stream] -> run_streaming(task, mode)
      true -> run_default(task, mode)
    end
  end

  @spec run_orchestrator(String.t(), MiniAgent.Permission.mode()) :: :ok
  defp run_orchestrator(task, mode) do
    IO.puts("Orchestrator mode: decomposing into sub-agents...\n")
    output = MiniAgent.Orchestrator.run(task, mode: mode)
    IO.puts("\nDONE\n#{output}")
    :ok
  end

  @spec run_streaming(String.t(), MiniAgent.Permission.mode()) :: :ok
  defp run_streaming(task, mode) do
    IO.puts("Streaming enabled\n")
    {:ok, pid} = MiniAgent.start_link(task, mode: mode, stream: true)
    output = MiniAgent.run(pid)
    IO.puts("\nDONE\n#{output}")
    :ok
  end

  @spec run_default(String.t(), MiniAgent.Permission.mode()) :: :ok
  defp run_default(task, mode) do
    {:ok, pid} = MiniAgent.start_link(task, mode: mode)
    output = MiniAgent.run(pid)
    IO.puts("\nDONE\n#{output}")
    :ok
  end

  @spec prompt_task() :: String.t()
  defp prompt_task do
    IO.gets("Enter task for agent: ") |> to_string() |> String.trim()
  end
end
