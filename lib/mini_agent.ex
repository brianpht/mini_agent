defmodule MiniAgent do
  @moduledoc """
  Agent loop GenServer.

  Implements a perceive -> act -> observe cycle against the configured LLM.
  The loop terminates on DONE: in the assistant reply, max_iterations, or
  budget exhaustion.

  Start with start_link/2, then call run/1 to block until completion.
  """

  use GenServer

  alias MiniAgent.{Budget, Checkpoint, LLM.Retry, Memory, Permission, Tools}
  alias MiniAgent.Tools.Context

  @max_iterations Application.compile_env!(:mini_agent, :max_iterations)
  @run_timeout_ms 120_000
  @system_prompt """
  You are a coding agent. Use the available tools to explore and modify code.

  Rules:
  - Use tools only when needed. Do not repeat a tool call with the same arguments.
  - Once you have enough information, answer directly - do not call more tools.
  - When the task is fully complete, you MUST include the word DONE: somewhere in your response, followed by your final answer.
  - Example final response: "DONE: Here are the files in lib/: mini_agent.ex, ..."
  """

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            session_id: String.t() | nil,
            task: String.t() | nil,
            messages: list(map()),
            iterations: non_neg_integer(),
            done: boolean(),
            output: String.t() | nil,
            tool_calls: list(map()),
            last: String.t() | nil,
            budget: Budget.t() | nil,
            mode: MiniAgent.Permission.mode(),
            workspace: String.t() | nil,
            stream_callback: (String.t() -> :ok) | nil,
            autosave: boolean()
          }

    defstruct [
      :session_id,
      :task,
      :output,
      :last,
      :budget,
      :workspace,
      :stream_callback,
      messages: [],
      iterations: 0,
      done: false,
      tool_calls: [],
      mode: :ask,
      autosave: false
    ]
  end

  @doc "Start the agent GenServer linked to the calling process."
  @spec start_link(String.t(), keyword()) :: GenServer.on_start()
  def start_link(task, opts \\ []) do
    GenServer.start_link(__MODULE__, {:new, task, opts})
  end

  @doc """
  Resume an agent from a previously saved checkpoint.

  Returns {:ok, pid} on success, or {:error, reason} if the session cannot
  be loaded. The resumed agent continues from the iteration after the last
  saved one, spending no extra tokens re-doing completed work.
  """
  @spec resume(Checkpoint.session_id(), keyword()) ::
          {:ok, pid()} | {:error, String.t()}
  def resume(session_id, opts \\ []) do
    case Checkpoint.load(session_id) do
      {:ok, base_state} ->
        autosave = Keyword.get(opts, :autosave, true)

        stream_callback =
          cond do
            Keyword.has_key?(opts, :stream_callback) -> Keyword.get(opts, :stream_callback)
            Keyword.get(opts, :stream, false) -> &IO.write/1
            true -> nil
          end

        mode = Keyword.get(opts, :mode, base_state.mode)

        state = %{
          base_state
          | autosave: autosave,
            stream_callback: stream_callback,
            mode: mode
        }

        GenServer.start_link(__MODULE__, {:resume, state})

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Run the agent loop and block until done. Returns the final output string."
  @spec run(pid()) :: String.t()
  def run(pid) do
    GenServer.call(pid, :run, @run_timeout_ms)
  end

  @impl GenServer
  def init({:new, task, opts}) do
    Process.flag(:trap_exit, true)

    stream_callback =
      cond do
        Keyword.has_key?(opts, :stream_callback) -> Keyword.get(opts, :stream_callback)
        Keyword.get(opts, :stream, false) -> &IO.write/1
        true -> nil
      end

    session_id =
      Keyword.get_lazy(opts, :session_id, &Checkpoint.new_session_id/0)

    state = %State{
      session_id: session_id,
      task: task,
      budget: Budget.new(),
      mode: Keyword.get(opts, :mode, :ask),
      workspace:
        Keyword.get_lazy(opts, :workspace, fn ->
          Application.get_env(:mini_agent, :workspace, File.cwd!())
        end),
      autosave: Keyword.get(opts, :autosave, false),
      stream_callback: stream_callback
    }

    {:ok, state}
  end

  def init({:resume, %State{} = state}) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:run, _from, state) do
    final = loop(state)
    {:reply, final.output || "(no output)", final}
  end

  # Trap-exit is set in init/1 so that terminate/2 is always called for
  # autosave. Tools (ShellTool via System.cmd Port, FileTool) link their
  # short-lived OS processes to this agent. When those processes exit normally
  # the BEAM converts the exit signal into an {:EXIT, pid, :normal} message.
  # Drop them silently - they are not errors, just cleanup noise.
  @impl GenServer
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %State{autosave: true} = state) do
    Checkpoint.save(state)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- loop ---

  @spec loop(State.t()) :: State.t()
  defp loop(%State{done: true} = state), do: state

  defp loop(%State{iterations: i} = state) when i >= @max_iterations do
    %{state | done: true, output: "Max iterations (#{@max_iterations}) reached"}
  end

  defp loop(%State{} = state) do
    if Budget.exceeded?(state.budget) do
      :telemetry.execute(
        [:mini_agent, :budget, :exceeded],
        %{used: state.budget.used},
        %{report: Budget.report(state.budget), session_id: state.session_id}
      )

      %{state | done: true, output: "Budget exceeded. #{Budget.report(state.budget)}"}
    else
      :telemetry.execute(
        [:mini_agent, :iteration, :start],
        %{iteration: state.iterations},
        %{session_id: state.session_id}
      )

      state
      |> perceive()
      |> act()
      |> observe()
      |> tick()
      |> maybe_checkpoint()
      |> loop()
    end
  end

  # --- perceive ---

  @spec perceive(State.t()) :: State.t()
  defp perceive(%State{messages: []} = state) do
    %{state | messages: [%{"role" => "user", "content" => state.task}]}
  end

  defp perceive(%State{} = state) do
    compressed = Memory.maybe_compress(state.messages, state.budget)
    %{state | messages: compressed}
  end

  # --- act ---

  @spec act(State.t()) :: State.t()
  defp act(%State{done: true} = state), do: state

  defp act(%State{} = state) do
    mod = llm_module()
    llm_opts = [system: @system_prompt, tools: Tools.definitions()]

    result =
      case state.stream_callback do
        nil ->
          Retry.with_retry(fn -> mod.chat(state.messages, llm_opts) end)

        # Streaming: retry only if no chunk has been received yet (connect-only retry).
        # Once the first chunk reaches the caller, errors are not retried to
        # prevent duplicate output.
        cb ->
          Retry.with_retry_stream(
            fn guarded_cb -> mod.chat_stream(state.messages, guarded_cb, llm_opts) end,
            cb
          )
      end

    case result do
      {:ok, resp} ->
        tokens = mod.usage(resp)
        calls = mod.extract_tool_calls(resp)
        text = mod.extract_text(resp)
        assistant = %{"role" => "assistant", "content" => resp["content"]}

        %{
          state
          | messages: state.messages ++ [assistant],
            tool_calls: calls,
            last: text,
            output: text,
            budget: Budget.add(state.budget, tokens)
        }

      {:error, reason} ->
        %{state | done: true, output: "LLM error: #{reason}"}
    end
  end

  # --- observe ---

  @spec observe(State.t()) :: State.t()
  defp observe(%State{done: true} = state), do: state

  defp observe(%State{tool_calls: [_ | _] = calls} = state) do
    ctx = %Context{
      mode: state.mode,
      workspace: state.workspace || Application.get_env(:mini_agent, :workspace, File.cwd!()),
      session_id: state.session_id
    }

    results =
      Enum.map(calls, fn call ->
        tool_name = call["name"]
        tool_input = call["input"]

        output =
          case Permission.check(tool_name, tool_input, state.mode) do
            :allow -> Tools.execute(tool_name, tool_input, ctx)
            {:deny, reason} -> "Denied: #{reason}"
          end

        %{"type" => "tool_result", "tool_use_id" => call["id"], "content" => output}
      end)

    # From iteration 2 onwards, append a nudge text block in the same user turn.
    # Valid for Anthropic (mixed content user turn) and DeepSeek (see convert_message).
    content =
      if state.iterations >= 2 do
        nudge = %{
          "type" => "text",
          "text" =>
            "You have now used tools across #{state.iterations + 1} iterations. " <>
              "If you have gathered enough information to complete the task, provide your final answer now and include 'DONE:' in the response. " <>
              "Only use more tools if you are genuinely missing required information."
        }

        results ++ [nudge]
      else
        results
      end

    tool_msg = %{"role" => "user", "content" => content}
    %{state | messages: state.messages ++ [tool_msg], tool_calls: []}
  end

  defp observe(%State{last: last} = state) when is_binary(last) do
    if String.contains?(last, "DONE:") do
      %{state | done: true}
    else
      continue_msg = %{
        "role" => "user",
        "content" =>
          "You have not finished yet. Continue working. When the task is complete, include 'DONE:' in your response followed by your final answer."
      }

      %{state | messages: state.messages ++ [continue_msg]}
    end
  end

  defp observe(state), do: state

  # --- tick ---

  @spec tick(State.t()) :: State.t()
  defp tick(state), do: %{state | iterations: state.iterations + 1}

  @spec llm_module() :: module()
  defp llm_module, do: Application.fetch_env!(:mini_agent, :llm_module)

  # Save a checkpoint after each completed iteration when autosave is enabled.
  @spec maybe_checkpoint(State.t()) :: State.t()
  defp maybe_checkpoint(%State{autosave: true} = state) do
    sid = Checkpoint.save(state)

    :telemetry.execute(
      [:mini_agent, :checkpoint, :saved],
      %{iterations: state.iterations},
      %{session_id: sid}
    )

    %{state | session_id: sid}
  end

  defp maybe_checkpoint(state), do: state
end
