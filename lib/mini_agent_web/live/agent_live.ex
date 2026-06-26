defmodule MiniAgentWeb.AgentLive do
  @moduledoc """
  LiveView UI for MiniAgent.

  Provides a split-pane interface: left column shows a live activity feed of
  telemetry events (iterations, tool calls, budget alerts); right column has
  a task input form on top and a streaming output panel on the bottom.

  The options panel (collapsed by default) exposes:
  - mode       :ask | :readonly | :auto
  - parallel   boolean - uses Orchestrator instead of single agent
  - workspace  string  - override sandbox root

  The sessions panel lists saved checkpoints and allows resuming them.
  """

  use Phoenix.LiveView, layout: {MiniAgentWeb.Layouts, :root}

  alias MiniAgent.{AgentBroadcaster, Checkpoint, Orchestrator}

  @pubsub MiniAgent.PubSub
  @default_workspace Application.compile_env(:mini_agent, :workspace, ".")

  # ---------------------------------------------------------------------------
  # mount
  # ---------------------------------------------------------------------------

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    session_id = Checkpoint.new_session_id()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(@pubsub, "agent:#{session_id}")
    end

    socket =
      assign(socket,
        # task state
        task: "",
        session_id: session_id,
        status: :idle,
        events: [],
        output: "",
        # options
        mode: :auto,
        parallel: false,
        workspace: @default_workspace,
        default_workspace: @default_workspace,
        show_options: false,
        # sessions panel
        sessions: [],
        show_sessions: false,
        # task monitoring
        task_ref: nil
      )

    {:ok, socket}
  end

  # ---------------------------------------------------------------------------
  # handle_event - options toggles
  # ---------------------------------------------------------------------------

  @impl Phoenix.LiveView
  def handle_event("toggle_options", _params, socket) do
    {:noreply, update(socket, :show_options, &(!&1))}
  end

  def handle_event("set_mode", %{"mode" => mode}, socket) do
    atom =
      case mode do
        "readonly" -> :readonly
        "auto" -> :auto
        _ -> :ask
      end

    {:noreply, assign(socket, mode: atom)}
  end

  def handle_event("toggle_parallel", _params, socket) do
    {:noreply, update(socket, :parallel, &(!&1))}
  end

  def handle_event("set_workspace", %{"workspace" => ws}, socket) do
    trimmed = String.trim(ws)
    workspace = if trimmed == "", do: @default_workspace, else: trimmed
    {:noreply, assign(socket, workspace: workspace)}
  end

  # ---------------------------------------------------------------------------
  # handle_event - sessions panel
  # ---------------------------------------------------------------------------

  def handle_event("toggle_sessions", _params, socket) do
    sessions = if socket.assigns.show_sessions, do: [], else: Checkpoint.list()
    {:noreply, assign(socket, show_sessions: !socket.assigns.show_sessions, sessions: sessions)}
  end

  def handle_event("resume", %{"sid" => sid}, socket) do
    old_sid = socket.assigns.session_id

    if connected?(socket) do
      Phoenix.PubSub.unsubscribe(@pubsub, "agent:#{old_sid}")
      Phoenix.PubSub.subscribe(@pubsub, "agent:#{sid}")
    end

    stream_callback = build_stream_callback(sid)
    mode = socket.assigns.mode

    %Task{pid: task_pid} =
      Task.Supervisor.async_nolink(MiniAgent.TaskSupervisor, fn ->
        case MiniAgent.resume(sid, stream_callback: stream_callback, mode: mode) do
          {:ok, pid} ->
            result = MiniAgent.run(pid)

            AgentBroadcaster.broadcast(sid, %{
              type: :done,
              result: result,
              timestamp: DateTime.utc_now()
            })

          {:error, reason} ->
            AgentBroadcaster.broadcast(sid, %{
              type: :done,
              result: "Error resuming: #{reason}",
              timestamp: DateTime.utc_now()
            })
        end
      end)

    task_ref = Process.monitor(task_pid)

    # Get task label from sessions list for display
    task_label =
      socket.assigns.sessions
      |> Enum.find(&(&1.session_id == sid))
      |> case do
        %{task: t} -> t
        _ -> "(resumed)"
      end

    socket =
      assign(socket,
        task: task_label,
        session_id: sid,
        status: :running,
        events: [],
        output: "",
        show_sessions: false,
        task_ref: task_ref
      )

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # handle_event - run / clear
  # ---------------------------------------------------------------------------

  def handle_event("run", %{"task" => task}, socket) when byte_size(task) == 0 do
    {:noreply, socket}
  end

  def handle_event("run", _params, %{assigns: %{status: :running}} = socket) do
    {:noreply, socket}
  end

  def handle_event("run", %{"task" => task}, socket) do
    %{session_id: session_id, mode: mode, parallel: parallel, workspace: workspace} =
      socket.assigns

    stream_callback = build_stream_callback(session_id)

    %Task{pid: task_pid} =
      Task.Supervisor.async_nolink(MiniAgent.TaskSupervisor, fn ->
        result =
          if parallel do
            Orchestrator.run(task, mode: mode, workspace: workspace, session_id: session_id)
          else
            {:ok, pid} =
              MiniAgent.start_link(task,
                session_id: session_id,
                stream_callback: stream_callback,
                mode: mode,
                workspace: workspace
              )

            MiniAgent.run(pid)
          end

        AgentBroadcaster.broadcast(session_id, %{
          type: :done,
          result: result,
          timestamp: DateTime.utc_now()
        })
      end)

    task_ref = Process.monitor(task_pid)

    socket =
      assign(socket,
        task: task,
        session_id: session_id,
        status: :running,
        events: [],
        output: "",
        task_ref: task_ref
      )

    {:noreply, socket}
  end

  def handle_event("clear", _params, socket) do
    session_id = Checkpoint.new_session_id()

    if connected?(socket) do
      Phoenix.PubSub.unsubscribe(@pubsub, "agent:#{socket.assigns.session_id}")
      Phoenix.PubSub.subscribe(@pubsub, "agent:#{session_id}")
    end

    socket =
      assign(socket,
        task: "",
        session_id: session_id,
        status: :idle,
        events: [],
        output: ""
      )

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # handle_info - PubSub events
  # ---------------------------------------------------------------------------

  @impl Phoenix.LiveView
  def handle_info({:agent_event, %{type: :iteration_start} = ev}, socket) do
    entry = %{
      icon: "iter",
      color: "blue",
      label: "Iteration #{ev.iteration + 1}",
      time: format_time(ev.timestamp)
    }

    {:noreply, update(socket, :events, &[entry | &1])}
  end

  def handle_info({:agent_event, %{type: :tool_executed} = ev}, socket) do
    entry = %{
      icon: "tool",
      color: "green",
      label: "Tool: #{ev.tool}",
      time: format_time(ev.timestamp)
    }

    {:noreply, update(socket, :events, &[entry | &1])}
  end

  def handle_info({:agent_event, %{type: :budget_exceeded} = ev}, socket) do
    entry = %{
      icon: "warn",
      color: "red",
      label: "Budget exceeded - #{ev.report}",
      time: format_time(ev.timestamp)
    }

    {:noreply,
     socket
     |> update(:events, &[entry | &1])
     |> assign(status: :error)}
  end

  def handle_info({:agent_event, %{type: :stream_chunk, chunk: chunk}}, socket) do
    {:noreply, update(socket, :output, &(&1 <> chunk))}
  end

  def handle_info({:agent_event, %{type: :done, result: result}}, socket) do
    entry = %{icon: "done", color: "gray", label: "Done", time: format_time(DateTime.utc_now())}

    if socket.assigns.task_ref, do: Process.demonitor(socket.assigns.task_ref, [:flush])

    {:noreply,
     socket
     |> assign(output: result, status: :done, task_ref: nil)
     |> update(:events, &[entry | &1])}
  end

  def handle_info({:agent_event, %{type: :orchestrator_start} = ev}, socket) do
    entry = %{
      icon: "plan",
      color: "blue",
      label: "Planning sub-tasks...",
      time: format_time(ev.timestamp)
    }

    {:noreply, update(socket, :events, &[entry | &1])}
  end

  def handle_info({:agent_event, %{type: :orchestrator_planned, count: n} = ev}, socket) do
    entry = %{
      icon: "plan",
      color: "blue",
      label: "Planned #{n} sub-tasks",
      time: format_time(ev.timestamp)
    }

    {:noreply, update(socket, :events, &[entry | &1])}
  end

  def handle_info({:agent_event, %{type: :sub_agent_start, id: id} = ev}, socket) do
    entry = %{
      icon: "sub",
      color: "blue",
      label: "Sub-agent #{id} started",
      time: format_time(ev.timestamp)
    }

    {:noreply, update(socket, :events, &[entry | &1])}
  end

  def handle_info({:agent_event, %{type: :sub_agent_done, id: id} = ev}, socket) do
    entry = %{
      icon: "sub",
      color: "green",
      label: "Sub-agent #{id} done",
      time: format_time(ev.timestamp)
    }

    {:noreply, update(socket, :events, &[entry | &1])}
  end

  def handle_info({:agent_event, %{type: :sub_agents_done, total_tokens: tokens} = ev}, socket) do
    entry = %{
      icon: "sync",
      color: "blue",
      label: "Synthesizing... (#{tokens} tokens used)",
      time: format_time(ev.timestamp)
    }

    {:noreply, update(socket, :events, &[entry | &1])}
  end

  # Task supervisor DOWN message on crash
  def handle_info({:DOWN, _ref, :process, _pid, reason}, socket) when reason != :normal do
    entry = %{
      icon: "warn",
      color: "red",
      label: "Agent crashed: #{inspect(reason)}",
      time: format_time(DateTime.utc_now())
    }

    {:noreply,
     socket
     |> update(:events, &[entry | &1])
     |> assign(status: :error)}
  end

  def handle_info({ref, _result}, socket) when is_reference(ref) do
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # render
  # ---------------------------------------------------------------------------

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="flex flex-col md:flex-row h-screen bg-gray-950 text-gray-100 font-mono overflow-hidden">

      <%!-- Left: Activity Feed --%>
      <div class="w-full md:w-72 flex-shrink-0 flex flex-col border-r border-gray-800">
        <div class="px-4 py-3 border-b border-gray-800 flex items-center justify-between">
          <span class="text-xs font-semibold text-gray-400 uppercase tracking-widest">Activity</span>
          <span class={["text-xs px-2 py-0.5 rounded-full font-semibold", status_badge_class(@status)]}>
            <%= status_label(@status) %>
          </span>
        </div>
        <div
          id="activity-feed"
          phx-hook="ScrollBottom"
          class="flex-1 overflow-y-auto px-3 py-2 space-y-1"
        >
          <%= for entry <- Enum.reverse(@events) do %>
            <div class="flex items-start gap-2 py-1">
              <span class={["mt-0.5 text-xs font-bold uppercase w-8 text-center", event_color_class(entry.color)]}>
                <%= entry.icon %>
              </span>
              <div class="flex-1 min-w-0">
                <p class="text-xs text-gray-200 break-words"><%= entry.label %></p>
                <p class="text-xs text-gray-600"><%= entry.time %></p>
              </div>
            </div>
          <% end %>
          <%= if @events == [] do %>
            <p class="text-xs text-gray-600 mt-4 text-center">No events yet</p>
          <% end %>
        </div>
      </div>

      <%!-- Right: Input + Options + Output --%>
      <div class="flex-1 flex flex-col min-w-0 overflow-hidden">

        <%!-- Task input area --%>
        <div class="border-b border-gray-800 p-4 flex flex-col gap-3">
          <form id="task-form" phx-submit="run" class="flex flex-col gap-2">
            <textarea
              name="task"
              rows="3"
              placeholder="Enter task for the agent..."
              class="w-full bg-gray-900 border border-gray-700 rounded px-3 py-2 text-sm text-gray-100 placeholder-gray-600 focus:outline-none focus:border-blue-500 resize-none"
              disabled={@status == :running}
            ><%= @task %></textarea>

            <%!-- Action row --%>
            <div class="flex items-center gap-2 flex-wrap">
              <%!-- Run button --%>
              <button
                type="submit"
                disabled={@status == :running}
                class={[
                  "px-4 py-1.5 rounded text-sm font-semibold transition-colors",
                  if(@status == :running,
                    do: "bg-gray-700 text-gray-500 cursor-not-allowed",
                    else: "bg-blue-600 hover:bg-blue-500 text-white cursor-pointer"
                  )
                ]}
              >
                <%= if @status == :running do %>
                  <span class="inline-flex items-center gap-1.5">
                    <svg class="animate-spin h-3.5 w-3.5" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                      <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                      <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"></path>
                    </svg>
                    Running...
                  </span>
                <% else %>
                  Run
                <% end %>
              </button>
              <%!-- Clear --%>
              <button
                type="button"
                phx-click="clear"
                class="px-3 py-1.5 rounded text-sm font-semibold bg-gray-800 hover:bg-gray-700 text-gray-300 cursor-pointer transition-colors"
              >
                Clear
              </button>
              <%!-- Options toggle --%>
              <button
                type="button"
                phx-click="toggle_options"
                class={[
                  "px-3 py-1.5 rounded text-sm font-semibold transition-colors cursor-pointer",
                  if(@show_options,
                    do: "bg-gray-700 text-gray-200",
                    else: "bg-gray-800 hover:bg-gray-700 text-gray-400"
                  )
                ]}
              >
                ⚙ Options
              </button>
              <%!-- Sessions toggle --%>
              <button
                type="button"
                phx-click="toggle_sessions"
                class={[
                  "px-3 py-1.5 rounded text-sm font-semibold transition-colors cursor-pointer",
                  if(@show_sessions,
                    do: "bg-gray-700 text-gray-200",
                    else: "bg-gray-800 hover:bg-gray-700 text-gray-400"
                  )
                ]}
              >
                ⟳ Sessions
              </button>
              <span class="text-xs text-gray-600 ml-auto hidden sm:block">
                session: <%= String.slice(@session_id, 0, 16) %>
              </span>
            </div>
          </form>

          <%!-- Options panel --%>
          <%= if @show_options do %>
            <div class="bg-gray-900 rounded border border-gray-700 p-3 flex flex-col gap-3 text-xs">
              <%!-- Mode --%>
              <div class="flex items-center gap-3">
                <span class="text-gray-400 w-20 flex-shrink-0">Mode</span>
                <div class="flex gap-1">
                  <%= for {label, val} <- [{"ask", :ask}, {"readonly", :readonly}, {"auto", :auto}] do %>
                    <button
                      type="button"
                      phx-click="set_mode"
                      phx-value-mode={label}
                      class={[
                        "px-3 py-1 rounded font-semibold transition-colors cursor-pointer",
                        if(@mode == val,
                          do: "bg-blue-700 text-white",
                          else: "bg-gray-800 hover:bg-gray-700 text-gray-400"
                        )
                      ]}
                    >
                      <%= label %>
                    </button>
                  <% end %>
                </div>
                <span class="text-gray-600 text-xs"><%= mode_hint(@mode) %></span>
              </div>

              <%!-- Parallel --%>
              <div class="flex items-center gap-3">
                <span class="text-gray-400 w-20 flex-shrink-0">Parallel</span>
                <button
                  type="button"
                  phx-click="toggle_parallel"
                  class={[
                    "px-3 py-1 rounded font-semibold transition-colors cursor-pointer",
                    if(@parallel,
                      do: "bg-purple-700 text-white",
                      else: "bg-gray-800 hover:bg-gray-700 text-gray-400"
                    )
                  ]}
                >
                  <%= if @parallel, do: "ON", else: "OFF" %>
                </button>
                <span class="text-gray-600">Fan-out to sub-agents via Orchestrator</span>
              </div>

              <%!-- Workspace --%>
              <div class="flex items-center gap-3">
                <span class="text-gray-400 w-20 flex-shrink-0">Workspace</span>
                <input
                  type="text"
                  phx-blur="set_workspace"
                  name="workspace"
                  value={@workspace}
                  placeholder={@default_workspace}
                  class="flex-1 bg-gray-800 border border-gray-600 rounded px-2 py-1 text-gray-100 placeholder-gray-600 focus:outline-none focus:border-blue-500 text-xs"
                />
              </div>
            </div>
          <% end %>

          <%!-- Sessions panel --%>
          <%= if @show_sessions do %>
            <div class="bg-gray-900 rounded border border-gray-700 text-xs max-h-48 overflow-y-auto">
              <%= if @sessions == [] do %>
                <p class="text-gray-600 p-3">No saved checkpoints</p>
              <% else %>
                <%= for s <- @sessions do %>
                  <div class="flex items-center gap-2 px-3 py-2 border-b border-gray-800 hover:bg-gray-800">
                    <div class="flex-1 min-w-0">
                      <p class="text-gray-200 truncate"><%= s.task %></p>
                      <p class="text-gray-600">
                        <%= s.session_id %> &middot; iter <%= s.iterations %> &middot; <%= s.tokens %> tokens &middot; <%= if s.done, do: "done", else: "in progress" %>
                      </p>
                    </div>
                    <%= unless s.done do %>
                      <button
                        type="button"
                        phx-click="resume"
                        phx-value-sid={s.session_id}
                        class="px-2 py-1 rounded bg-blue-800 hover:bg-blue-700 text-blue-200 font-semibold flex-shrink-0 cursor-pointer"
                      >
                        Resume
                      </button>
                    <% end %>
                  </div>
                <% end %>
              <% end %>
            </div>
          <% end %>
        </div>

        <%!-- Output panel --%>
        <div
          id="output-panel"
          phx-hook="ScrollBottom"
          class="flex-1 overflow-y-auto p-4 bg-gray-950"
        >
          <%= if @output == "" do %>
            <p class="text-xs text-gray-600">Output will appear here once the agent starts...</p>
          <% else %>
            <pre class="text-sm text-green-300 whitespace-pre-wrap break-words leading-relaxed"><%= @output %></pre>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # private helpers
  # ---------------------------------------------------------------------------

  @spec build_stream_callback(String.t()) :: (String.t() -> :ok)
  defp build_stream_callback(session_id) do
    fn chunk ->
      AgentBroadcaster.broadcast(session_id, %{
        type: :stream_chunk,
        chunk: chunk,
        timestamp: DateTime.utc_now()
      })
    end
  end

  @spec status_label(atom()) :: String.t()
  defp status_label(:idle), do: "idle"
  defp status_label(:running), do: "running"
  defp status_label(:done), do: "done"
  defp status_label(:error), do: "error"

  @spec status_badge_class(atom()) :: String.t()
  defp status_badge_class(:idle), do: "bg-gray-800 text-gray-400"
  defp status_badge_class(:running), do: "bg-blue-900 text-blue-300"
  defp status_badge_class(:done), do: "bg-green-900 text-green-300"
  defp status_badge_class(:error), do: "bg-red-900 text-red-300"

  @spec event_color_class(String.t()) :: String.t()
  defp event_color_class("blue"), do: "text-blue-400"
  defp event_color_class("green"), do: "text-green-400"
  defp event_color_class("red"), do: "text-red-400"
  defp event_color_class(_), do: "text-gray-400"

  @spec mode_hint(atom()) :: String.t()
  defp mode_hint(:ask), do: "prompt before write/shell"
  defp mode_hint(:readonly), do: "read-only, no writes"
  defp mode_hint(:auto), do: "approve all tools"

  @spec format_time(DateTime.t()) :: String.t()
  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end
end
