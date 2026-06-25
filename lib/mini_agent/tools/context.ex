defmodule MiniAgent.Tools.Context do
  @moduledoc false

  # Execution context threaded through every Tools.execute/3 call.
  # Carries per-call concerns that vary between agent and sub-agent:
  #   - mode       - permission level (:auto | :readonly | :ask)
  #   - workspace  - sandbox root passed down from the agent boundary so that
  #                  FileTool and ShellTool never read Application.get_env in
  #                  a concurrent hot path.
  #   - session_id - agent session identifier used for telemetry routing;
  #                  nil when called from sub-agents that have no LiveView session.

  @enforce_keys [:mode, :workspace]

  @type t :: %__MODULE__{
          mode: MiniAgent.Permission.mode(),
          workspace: String.t(),
          session_id: String.t() | nil
        }

  defstruct [:mode, :workspace, session_id: nil]
end
