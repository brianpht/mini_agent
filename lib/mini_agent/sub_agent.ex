defmodule MiniAgent.SubAgent do
  @moduledoc """
  A lightweight agent loop for delegated sub-tasks.

  Runs as a pure function (no GenServer) with its own message history and
  token budget. Sub-agents cannot spawn further sub-agents - they receive
  Tools.safe_definitions/0 which excludes the delegate tool, preventing
  recursive fan-out.

  Designed to be called from MiniAgent.Orchestrator via Task.Supervisor.
  """

  alias MiniAgent.{Budget, LLM.Retry, Permission, Tools}

  @max_iter 8
  @sub_budget 25_000
  @system_prompt """
  You are a focused sub-agent completing exactly one specific task.
  Use tools as needed, but do not repeat the same tool call with the same arguments.
  Once you have the information required, answer directly.
  When done, include 'DONE:' in your response followed by a concise summary of what you found or did.
  Example: "DONE: The lib/ directory contains 12 files including mini_agent.ex and budget.ex."
  """

  @type sub_state :: %{
          messages: list(map()),
          iter: non_neg_integer(),
          budget: Budget.t(),
          mode: Permission.mode(),
          id: term(),
          output: String.t() | nil,
          done: boolean()
        }

  @doc """
  Run a sub-task to completion. Returns {:ok, output} | {:error, reason}.

  Options:
    - :mode  - :auto | :readonly | :ask (default: :readonly)
    - :id    - identifier for logging (default: "?")
  """
  @spec run(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(subtask, opts \\ []) do
    mode = Keyword.get(opts, :mode, :readonly)
    id = Keyword.get(opts, :id, "?")

    state = %{
      messages: [%{"role" => "user", "content" => subtask}],
      iter: 0,
      budget: %Budget{limit: @sub_budget},
      mode: mode,
      id: id,
      output: nil,
      done: false
    }

    final = loop(state)
    {:ok, final.output || "(sub-agent #{id} produced no output)"}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # --- loop ---

  @spec loop(sub_state()) :: sub_state()
  defp loop(%{done: true} = s), do: s

  defp loop(%{iter: i} = s) when i >= @max_iter do
    %{s | done: true, output: s.output || "(sub-agent #{s.id} reached iteration limit)"}
  end

  defp loop(s) do
    if Budget.exceeded?(s.budget) do
      %{s | done: true, output: s.output || "(sub-agent #{s.id} exceeded token budget)"}
    else
      s
      |> step()
      |> Map.update!(:iter, &(&1 + 1))
      |> loop()
    end
  end

  # --- step ---

  @spec step(sub_state()) :: sub_state()
  defp step(s) do
    mod = llm_module()

    case Retry.with_retry(fn ->
           mod.chat(s.messages, system: @system_prompt, tools: Tools.safe_definitions())
         end) do
      {:ok, resp} ->
        calls = mod.extract_tool_calls(resp)
        text = mod.extract_text(resp)
        budget = Budget.add(s.budget, mod.usage(resp))
        assistant = %{"role" => "assistant", "content" => resp["content"]}
        s = %{s | budget: budget, messages: s.messages ++ [assistant], output: text}

        cond do
          calls != [] ->
            results = execute_tools(calls, s.mode, s.iter)
            tool_msg = %{"role" => "user", "content" => results}
            %{s | messages: s.messages ++ [tool_msg]}

          String.contains?(text, "DONE:") ->
            %{s | done: true}

          true ->
            continue_msg = %{
              "role" => "user",
              "content" =>
                "Continue working. When done, include 'DONE:' in your response followed by your answer."
            }

            %{s | messages: s.messages ++ [continue_msg]}
        end

      {:error, reason} ->
        %{s | done: true, output: "LLM error in sub-agent #{s.id}: #{reason}"}
    end
  end

  @spec execute_tools(list(map()), Permission.mode(), non_neg_integer()) :: list(map())
  defp execute_tools(calls, mode, iter) do
    results =
      Enum.map(calls, fn call ->
        output =
          case Permission.check(call["name"], call["input"], mode) do
            :allow -> Tools.execute(call["name"], call["input"], mode)
            {:deny, reason} -> "Denied: #{reason}"
          end

        %{"type" => "tool_result", "tool_use_id" => call["id"], "content" => output}
      end)

    if iter >= 2 do
      nudge = %{
        "type" => "text",
        "text" =>
          "You have used tools across #{iter + 1} iterations. " <>
            "If you have enough information, provide your final answer now and include 'DONE:'."
      }

      results ++ [nudge]
    else
      results
    end
  end

  @spec llm_module() :: module()
  defp llm_module, do: Application.fetch_env!(:mini_agent, :llm_module)
end
