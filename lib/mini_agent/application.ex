defmodule MiniAgent.Application do
  @moduledoc "OTP Application entry point. Starts the top-level supervision tree."

  use Application

  @impl Application
  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: MiniAgent.TaskSupervisor},
      {Phoenix.PubSub, name: MiniAgent.PubSub},
      MiniAgentWeb.Endpoint
    ]

    :ok = MiniAgent.Telemetry.attach_handlers()
    :ok = MiniAgent.AgentBroadcaster.attach_handlers()

    Supervisor.start_link(children, strategy: :one_for_one, name: MiniAgent.Supervisor)
  end
end
