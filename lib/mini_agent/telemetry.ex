defmodule MiniAgent.Telemetry do
  @moduledoc """
  Telemetry event handlers. The single location allowed to write log output to console.

  Note: MiniAgent.Permission.ask_user_async/2 is the intentional interactive I/O
  exception - it writes a prompt and reads stdin when mode is :ask. That is
  user-facing interactive I/O, not log output, and is not routed through telemetry.
  """

  @events [
    [:mini_agent, :tool, :executed],
    [:mini_agent, :budget, :exceeded],
    [:mini_agent, :memory, :compressed],
    [:mini_agent, :iteration, :start],
    [:mini_agent, :orchestrator, :total_spend]
  ]

  @doc "Attach all handlers. Called once from Application.start/2."
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

  @doc false
  @spec handle_event(list(atom()), map(), map(), term()) :: :ok
  def handle_event([:mini_agent, :tool, :executed], _m, %{name: name}, _) do
    IO.puts("  [tool] #{name}")
  end

  def handle_event([:mini_agent, :budget, :exceeded], _m, %{report: report}, _) do
    IO.puts("[budget] EXCEEDED - #{report}")
  end

  def handle_event([:mini_agent, :memory, :compressed], %{before: b, after: a}, _m, _) do
    IO.puts("[memory] Compressed context: #{b} -> #{a} messages")
  end

  def handle_event([:mini_agent, :iteration, :start], %{iteration: i}, _m, _) do
    sep = String.duplicate("-", 50)
    IO.puts("\n#{sep}\nIteration #{i}\n#{sep}")
  end

  def handle_event([:mini_agent, :orchestrator, :total_spend], m, _meta, _) do
    IO.puts(
      "[orchestrator] Total token spend: #{m.total} " <>
        "(plan: #{m.plan_tokens}, sub-agents: #{m.sub_tokens}, synthesize: #{m.synthesize_tokens})"
    )
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok
end
