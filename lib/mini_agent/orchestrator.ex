defmodule MiniAgent.Orchestrator do
  @moduledoc """
  Multi-agent orchestrator: plan -> parallel fan-out -> synthesize.

  Decomposes a complex task into independent sub-tasks using the LLM,
  runs each sub-task concurrently via MiniAgent.SubAgent under
  MiniAgent.TaskSupervisor, then synthesizes the collected results into
  a single coherent response.

  Called directly by MiniAgent.CLI with --parallel flag, or invoked
  from MiniAgent.Tools.execute/3 when the agent calls the delegate tool.

  ## Budget note

  Total token spend for one orchestrator run:
    plan_call + synthesize_call + sum(sub-agent budgets)

  Sub-agent budgets are independent and not deducted from the calling
  agent's budget. With 4 sub-agents each capped at SubAgent.@sub_budget,
  total spend can significantly exceed the caller's budget.limit. This is
  intentional (shared-nothing isolation) - set limits accordingly.

  Total spend is tracked and emitted via the
  `[:mini_agent, :orchestrator, :total_spend]` telemetry event with a full
  breakdown (plan_tokens, sub_tokens, synthesize_tokens, total).

  ## :ask mode in parallel context

  :ask mode requires interactive stdin prompts. Running it across N
  concurrent sub-agents would race on a single stdin file descriptor.
  Orchestrator.run/2 therefore downgrades :ask to :readonly automatically.
  Use :auto explicitly if you want sub-agents to approve dangerous tools
  without interaction.
  """

  alias MiniAgent.{LLM.Retry, SubAgent}

  @plan_system "You are a task planner. Output only a plain list of independent sub-tasks, one per line, no numbering, no explanation, no extra text."
  @synthesize_system "You are a results synthesizer. Combine findings from multiple sub-agents into one clear, complete answer."
  # Timeout for Task.yield_many/2 in run_parallel.
  # Worst case per sub-agent: @max_iter(8) * (LLM response ~30 s + retry backoff ~7 s) = ~296 s.
  # 300 s provides a safe margin for real API calls.
  @yield_timeout_ms 300_000

  @doc """
  Run a task using the orchestrator pattern.
  Returns the synthesized result string.

  Options:
    - :mode       - :auto | :readonly | :ask (default: :readonly).
                    :ask is downgraded to :readonly - see module doc.
    - :workspace  - sandbox root passed to sub-agents (default: Application env).
    - :llm_module - LLM implementation module (default: from Application env).
    - :session_id - session ID for telemetry routing.
  """
  @spec run(String.t(), keyword()) :: String.t()
  def run(task, opts \\ []) do
    raw_mode = Keyword.get(opts, :mode, :readonly)
    session_id = Keyword.get(opts, :session_id)

    llm_module =
      Keyword.get_lazy(opts, :llm_module, fn ->
        Application.fetch_env!(:mini_agent, :llm_module)
      end)

    # :ask spawns interactive stdin prompts; N concurrent Tasks would race on
    # the single stdin fd. Downgrade to :readonly so sub-agents can still read
    # files and list directories without blocking on user input.
    mode =
      if raw_mode == :ask do
        :telemetry.execute(
          [:mini_agent, :orchestrator, :ask_downgraded],
          %{},
          %{reason: "parallel tasks cannot share stdin", session_id: session_id}
        )

        :readonly
      else
        raw_mode
      end

    workspace =
      Keyword.get(opts, :workspace, Application.get_env(:mini_agent, :workspace, File.cwd!()))

    :telemetry.execute(
      [:mini_agent, :orchestrator, :start],
      %{},
      %{task: task, session_id: session_id}
    )

    {subtasks, plan_tokens} = plan(task, llm_module)

    :telemetry.execute(
      [:mini_agent, :orchestrator, :planned],
      %{subtask_count: length(subtasks)},
      %{session_id: session_id}
    )

    results = run_parallel(subtasks, mode, workspace, session_id, llm_module)

    sub_tokens = results |> Enum.map(&elem(&1, 3)) |> Enum.sum()

    :telemetry.execute(
      [:mini_agent, :orchestrator, :sub_agents_done],
      %{total_tokens: sub_tokens},
      %{subtask_count: length(results), session_id: session_id}
    )

    {final_text, synth_tokens} = synthesize(task, results, llm_module)

    grand_total = plan_tokens + sub_tokens + synth_tokens

    :telemetry.execute(
      [:mini_agent, :orchestrator, :total_spend],
      %{
        plan_tokens: plan_tokens,
        sub_tokens: sub_tokens,
        synthesize_tokens: synth_tokens,
        total: grand_total
      },
      %{session_id: session_id}
    )

    final_text
  end

  # --- plan ---

  @spec plan(String.t(), module()) :: {list(String.t()), non_neg_integer()}
  defp plan(task, llm_module) do
    prompt = [
      %{
        "role" => "user",
        "content" =>
          "Break the following task into 2-4 independent sub-tasks that can be done in parallel.\n" <>
            "Output only the sub-tasks, one per line, no numbering or prefixes.\n\n" <>
            "Task: #{task}"
      }
    ]

    case Retry.with_retry(fn -> llm_module.chat(prompt, system: @plan_system) end) do
      {:ok, resp} ->
        tokens = llm_module.usage(resp)

        subtasks =
          resp
          |> llm_module.extract_text()
          |> String.split("\n", trim: true)
          |> Enum.map(&strip_list_prefix/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.take(4)
          |> fallback_to_original(task)

        {subtasks, tokens}

      {:error, _} ->
        {[task], 0}
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

  @spec run_parallel(
          list(String.t()),
          MiniAgent.Permission.mode(),
          String.t(),
          String.t() | nil,
          module()
        ) ::
          list({non_neg_integer(), String.t(), String.t(), non_neg_integer()})
  defp run_parallel(subtasks, mode, workspace, session_id, llm_module) do
    indexed = Enum.with_index(subtasks, 1)

    # async_nolink: a single sub-agent crash does not kill the orchestrator
    tasks =
      Enum.map(indexed, fn {subtask, idx} ->
        Task.Supervisor.async_nolink(MiniAgent.TaskSupervisor, fn ->
          run_sub_agent(subtask, idx, mode, workspace, session_id, llm_module)
        end)
      end)

    # yield_many with generous timeout to cover LLM response time + retry backoff.
    tasks
    |> Task.yield_many(@yield_timeout_ms)
    |> Enum.zip(indexed)
    |> Enum.map(fn {{task, outcome}, {subtask, idx}} ->
      case outcome do
        {:ok, result} ->
          result

        {:exit, reason} ->
          {idx, subtask, "Sub-agent #{idx} crashed: #{inspect(reason)}", 0}

        nil ->
          Task.shutdown(task, :brutal_kill)
          {idx, subtask, "Sub-agent #{idx} timed out", 0}
      end
    end)
  end

  # --- sub_agent task body (extracted to keep run_parallel depth <= 2) ---

  @spec run_sub_agent(
          String.t(),
          non_neg_integer(),
          MiniAgent.Permission.mode(),
          String.t(),
          String.t() | nil,
          module()
        ) ::
          {non_neg_integer(), String.t(), String.t(), non_neg_integer()}
  defp run_sub_agent(subtask, idx, mode, workspace, session_id, llm_module) do
    :telemetry.execute(
      [:mini_agent, :orchestrator, :sub_agent_start],
      %{},
      %{id: idx, session_id: session_id}
    )

    {tokens, result} =
      case SubAgent.run(subtask,
             mode: mode,
             workspace: workspace,
             id: idx,
             llm_module: llm_module
           ) do
        {:ok, output, n} -> {n, output}
        {:error, reason} -> {0, "Error: #{reason}"}
      end

    :telemetry.execute(
      [:mini_agent, :orchestrator, :sub_agent_done],
      %{},
      %{id: idx, session_id: session_id}
    )

    {idx, subtask, result, tokens}
  end

  # --- synthesize ---

  @spec synthesize(
          String.t(),
          list({non_neg_integer(), String.t(), String.t(), non_neg_integer()}),
          module()
        ) ::
          {String.t(), non_neg_integer()}
  defp synthesize(task, results, llm_module) do
    findings =
      Enum.map_join(results, "\n\n", fn {idx, subtask, output, _tokens} ->
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

    case Retry.with_retry(fn -> llm_module.chat(prompt, system: @synthesize_system) end) do
      {:ok, resp} ->
        tokens = llm_module.usage(resp)
        {llm_module.extract_text(resp), tokens}

      {:error, reason} ->
        {"Synthesis failed (#{reason}). Raw results:\n\n#{findings}", 0}
    end
  end
end
