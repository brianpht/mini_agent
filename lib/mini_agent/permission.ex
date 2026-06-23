defmodule MiniAgent.Permission do
  @moduledoc """
  Permission gate for tool execution.

  Modes:
  - :auto     - allow all tool calls without prompting
  - :readonly - block any tool marked dangerous?, allow the rest
  - :ask      - prompt the user via stdin for dangerous tools
                (IO.gets runs in a supervised Task to avoid blocking the caller)

  Note: ask_user_async/2 is the intentional interactive I/O exception in this
  system. It writes prompts and reads stdin directly - user-facing interactive
  I/O, not log output. MiniAgent.Telemetry handles all log output; this is the
  only non-telemetry console I/O, and it must never be called from concurrent
  contexts (see Orchestrator module doc on :ask + --parallel).
  """

  @ask_timeout_ms 30_000

  @type mode :: :auto | :ask | :readonly
  @type result :: :allow | {:deny, String.t()}

  @doc "Check whether a tool call is permitted under the given mode."
  @spec check(String.t(), map(), mode()) :: result()
  def check(_tool_name, _input, :auto), do: :allow

  def check(tool_name, _input, :readonly) do
    if MiniAgent.Tools.dangerous?(tool_name) do
      {:deny, "readonly mode"}
    else
      :allow
    end
  end

  def check(tool_name, input, :ask) do
    if MiniAgent.Tools.dangerous?(tool_name) do
      ask_user_async(tool_name, input)
    else
      :allow
    end
  end

  @spec ask_user_async(String.t(), map()) :: result()
  defp ask_user_async(tool_name, input) do
    task =
      Task.Supervisor.async_nolink(MiniAgent.TaskSupervisor, fn ->
        IO.puts("\nAgent wants to run DANGEROUS tool:")
        IO.puts("  #{tool_name}(#{inspect(input)})")
        answer = IO.gets("  Allow? [y/N] ") |> to_string() |> String.trim() |> String.downcase()
        answer in ["y", "yes"]
      end)

    case Task.yield(task, @ask_timeout_ms) || Task.shutdown(task) do
      {:ok, true} -> :allow
      {:ok, false} -> {:deny, "user denied"}
      nil -> {:deny, "approval timed out"}
    end
  end
end
