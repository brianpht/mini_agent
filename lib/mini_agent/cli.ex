defmodule MiniAgent.CLI do
  @moduledoc "Escript entry point. Parses CLI args and drives the agent loop."

  @doc "Entry point for escript. Accepts optional --auto / --mode flags and a task string."
  @spec main(list(String.t())) :: :ok
  def main(args \\ []) do
    {opts, rest, _} =
      OptionParser.parse(args,
        switches: [mode: :string, auto: :boolean],
        aliases: [m: :mode, a: :auto]
      )

    mode =
      cond do
        opts[:auto] -> :auto
        opts[:mode] == "readonly" -> :readonly
        opts[:mode] == "ask" -> :ask
        true -> :ask
      end

    task =
      case rest do
        [] -> prompt_task()
        parts -> Enum.join(parts, " ")
      end

    IO.puts("\nMini Agent starting (mode: #{mode})")
    IO.puts("Task: #{task}\n")

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
