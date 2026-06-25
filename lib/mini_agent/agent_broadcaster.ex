defmodule MiniAgent.AgentBroadcaster do
  @moduledoc """
  Bridges agent telemetry events to Phoenix.PubSub for the LiveView UI.

  attach_handlers/0 - called once from Application.start/2. Attaches telemetry
  handlers that broadcast events on "agent:<session_id>" topics.

  broadcast/2 - called directly from LiveView task callbacks to push
  stream chunks and completion events to the subscribed LiveView process.

  Event shapes broadcast to "agent:<session_id>":
    %{type: :iteration_start, iteration: non_neg_integer(), timestamp: DateTime.t()}
    %{type: :tool_executed,   tool: String.t(),             timestamp: DateTime.t()}
    %{type: :budget_exceeded, report: String.t(),           timestamp: DateTime.t()}
    %{type: :stream_chunk,    chunk: String.t(),            timestamp: DateTime.t()}
    %{type: :done,            result: String.t(),           timestamp: DateTime.t()}
  """

  @pubsub MiniAgent.PubSub

  @events [
    [:mini_agent, :tool, :executed],
    [:mini_agent, :budget, :exceeded],
    [:mini_agent, :iteration, :start],
    [:mini_agent, :checkpoint, :saved],
    [:mini_agent, :orchestrator, :start],
    [:mini_agent, :orchestrator, :planned],
    [:mini_agent, :orchestrator, :sub_agent_start],
    [:mini_agent, :orchestrator, :sub_agent_done],
    [:mini_agent, :orchestrator, :sub_agents_done]
  ]

  @doc "Attach telemetry handlers. Called once from Application.start/2."
  @spec attach_handlers() :: :ok
  def attach_handlers do
    Enum.each(@events, fn event ->
      :telemetry.attach(
        {__MODULE__, event},
        event,
        &__MODULE__.handle_event/4,
        nil
      )
    end)
  end

  @doc "Broadcast an arbitrary map to the given session's PubSub topic."
  @spec broadcast(String.t(), map()) :: :ok
  def broadcast(session_id, payload) when is_binary(session_id) and is_map(payload) do
    Phoenix.PubSub.broadcast(@pubsub, "agent:#{session_id}", {:agent_event, payload})
    :ok
  end

  @doc false
  @spec handle_event(list(atom()), map(), map(), term()) :: :ok

  def handle_event([:mini_agent, :iteration, :start], %{iteration: i}, meta, _) do
    with_session(meta, fn sid ->
      broadcast(sid, %{type: :iteration_start, iteration: i, timestamp: DateTime.utc_now()})
    end)
  end

  def handle_event([:mini_agent, :tool, :executed], _measurements, meta, _) do
    with_session(meta, fn sid ->
      broadcast(sid, %{
        type: :tool_executed,
        tool: meta[:name] || "unknown",
        timestamp: DateTime.utc_now()
      })
    end)
  end

  def handle_event([:mini_agent, :budget, :exceeded], _measurements, meta, _) do
    with_session(meta, fn sid ->
      broadcast(sid, %{
        type: :budget_exceeded,
        report: meta[:report] || "budget exceeded",
        timestamp: DateTime.utc_now()
      })
    end)
  end

  def handle_event([:mini_agent, :checkpoint, :saved], _measurements, _meta, _), do: :ok

  def handle_event([:mini_agent, :orchestrator, :start], _measurements, meta, _) do
    with_session(meta, fn sid ->
      broadcast(sid, %{type: :orchestrator_start, timestamp: DateTime.utc_now()})
    end)
  end

  def handle_event([:mini_agent, :orchestrator, :planned], %{subtask_count: n}, meta, _) do
    with_session(meta, fn sid ->
      broadcast(sid, %{type: :orchestrator_planned, count: n, timestamp: DateTime.utc_now()})
    end)
  end

  def handle_event([:mini_agent, :orchestrator, :sub_agent_start], _measurements, meta, _) do
    with_session(meta, fn sid ->
      broadcast(sid, %{
        type: :sub_agent_start,
        id: meta[:id],
        timestamp: DateTime.utc_now()
      })
    end)
  end

  def handle_event([:mini_agent, :orchestrator, :sub_agent_done], _measurements, meta, _) do
    with_session(meta, fn sid ->
      broadcast(sid, %{
        type: :sub_agent_done,
        id: meta[:id],
        timestamp: DateTime.utc_now()
      })
    end)
  end

  def handle_event(
        [:mini_agent, :orchestrator, :sub_agents_done],
        %{total_tokens: tokens},
        meta,
        _
      ) do
    with_session(meta, fn sid ->
      broadcast(sid, %{
        type: :sub_agents_done,
        total_tokens: tokens,
        timestamp: DateTime.utc_now()
      })
    end)
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  @spec with_session(map(), (String.t() -> :ok)) :: :ok
  defp with_session(meta, fun) do
    case Map.get(meta, :session_id) do
      sid when is_binary(sid) -> fun.(sid)
      _ -> :ok
    end
  end
end
