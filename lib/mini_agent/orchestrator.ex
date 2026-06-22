defmodule MiniAgent.Orchestrator do
  @moduledoc """
  Multi-agent orchestrator: plan -> parallel fan-out -> synthesize.

  Decomposes a complex task into independent sub-tasks using the LLM,
  runs each sub-task concurrently via MiniAgent.SubAgent under
  MiniAgent.TaskSupervisor, then synthesizes the collected results into
  a single coherent response.

  Called directly by MiniAgent.CLI with --parallel flag, or invoked
  from MiniAgent.Tools.execute/2 when the agent calls the delegate tool.
  """

  alias MiniAgent.SubAgent

  @plan_system "You are a task planner. Output only a plain list of independent sub-tasks, one per line, no numbering, no explanation, no extra text."
  @synthesize_system "You are a results synthesizer. Combine findings from multiple sub-agents into one clear, complete answer."

  @doc """
  Run a task using the orchestrator pattern.
  Returns the synthesized result string.

  Options:
    - :mode - :auto | :readonly | :ask (default: :readonly)
  """
  @spec run(String.t(), keyword()) :: String.t()
  def run(task, opts \\ []) do
    mode = Keyword.get(opts, :mode, :readonly)

    :telemetry.execute([:mini_agent, :orchestrator, :start], %{}, %{task: task})

    subtasks = plan(task)

    :telemetry.execute(
      [:mini_agent, :orchestrator, :planned],
      %{subtask_count: length(subtasks)},
      %{}
    )

    results = run_parallel(subtasks, mode)
    synthesize(task, results)
  end

  # --- plan ---

  @spec plan(String.t()) :: list(String.t())
  defp plan(task) do
    prompt = [
      %{
        "role" => "user",
        "content" =>
          "Break the following task into 2-4 independent sub-tasks that can be done in parallel.\n" <>
            "Output only the sub-tasks, one per line, no numbering or prefixes.\n\n" <>
            "Task: #{task}"
      }
    ]

    case llm_module().chat(prompt, system: @plan_system) do
      {:ok, resp} ->
        resp
        |> llm_module().extract_text()
        |> String.split("\n", trim: true)
        |> Enum.map(&strip_list_prefix/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.take(4)
        |> fallback_to_original(task)

      {:error, _} ->
        [task]
    end
  end

  # compiled at module load - compliant with hot-path regex rule
  @list_prefix_re ~r/^[\d\.\)\-\*\s]+/

  @spec strip_list_prefix(String.t()) :: String.t()
  defp strip_list_prefix(line) do
    line |> String.replace(@list_prefix_re, "") |> String.trim()
  end

  @spec fallback_to_original(list(String.t()), String.t()) :: list(String.t())
  defp fallback_to_original([], task), do: [task]
  defp fallback_to_original(subtasks, _task), do: subtasks

  # --- run_parallel ---

  @spec run_parallel(list(String.t()), MiniAgent.Permission.mode()) ::
          list({non_neg_integer(), String.t(), String.t()})
  defp run_parallel(subtasks, mode) do
    indexed = Enum.with_index(subtasks, 1)

    # async_nolink: a single sub-agent crash does not kill the orchestrator
    tasks =
      Enum.map(indexed, fn {subtask, idx} ->
        Task.Supervisor.async_nolink(MiniAgent.TaskSupervisor, fn ->
          run_sub_agent(subtask, idx, mode)
        end)
      end)

    # yield_many: partial success if some sub-agents time out
    tasks
    |> Task.yield_many(120_000)
    |> Enum.zip(indexed)
    |> Enum.map(fn {{task, outcome}, {subtask, idx}} ->
      case outcome do
        {:ok, result} ->
          result

        {:exit, reason} ->
          {idx, subtask, "Sub-agent #{idx} crashed: #{inspect(reason)}"}

        nil ->
          Task.shutdown(task, :brutal_kill)
          {idx, subtask, "Sub-agent #{idx} timed out"}
      end
    end)
  end

  # --- sub_agent task body (extracted to keep run_parallel depth <= 2) ---

  @spec run_sub_agent(String.t(), non_neg_integer(), MiniAgent.Permission.mode()) ::
          {non_neg_integer(), String.t(), String.t()}
  defp run_sub_agent(subtask, idx, mode) do
    :telemetry.execute([:mini_agent, :orchestrator, :sub_agent_start], %{}, %{id: idx})

    result =
      case SubAgent.run(subtask, mode: mode, id: idx) do
        {:ok, output} -> output
        {:error, reason} -> "Error: #{reason}"
      end

    :telemetry.execute([:mini_agent, :orchestrator, :sub_agent_done], %{}, %{id: idx})
    {idx, subtask, result}
  end

  # --- synthesize ---

  @spec synthesize(String.t(), list({non_neg_integer(), String.t(), String.t()})) :: String.t()
  defp synthesize(task, results) do
    findings =
      Enum.map_join(results, "\n\n", fn {idx, subtask, output} ->
        "### Sub-agent #{idx}: #{subtask}\n#{output}"
      end)

    prompt = [
      %{
        "role" => "user",
        "content" =>
          "Original task: #{task}\n\n" <>
            "Results from sub-agents:\n#{findings}\n\n" <>
            "Synthesize these into a single complete answer for the original task."
      }
    ]

    case llm_module().chat(prompt, system: @synthesize_system) do
      {:ok, resp} ->
        llm_module().extract_text(resp)

      {:error, reason} ->
        "Synthesis failed (#{reason}). Raw results:\n\n#{findings}"
    end
  end

  @spec llm_module() :: module()
  defp llm_module, do: Application.fetch_env!(:mini_agent, :llm_module)
end
