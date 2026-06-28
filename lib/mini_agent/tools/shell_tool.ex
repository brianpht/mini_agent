defmodule MiniAgent.Tools.ShellTool do
  @moduledoc """
  Runs whitelisted shell commands sandboxed to workspace directory.

  The workspace root is passed explicitly by the caller (read once at the agent
  boundary) so that concurrent sub-agents can never interfere via a shared
  Application env key.

  The shell whitelist is config-driven via:

      config :mini_agent, :shell_whitelist, ~w[ls cat grep ...]

  Falls back to @default_whitelist at compile time if no config is present.

  Commands run with `cd: workspace` and via `System.cmd/3` (no shell is spawned,
  so there is no shell-metacharacter injection). Arguments are additionally
  confined to the workspace via `MiniAgent.Tools.Sandbox` so a path argument
  cannot escape (e.g. `cat ../../etc/passwd`).

  Limitation: the command string is split on whitespace, so quoted arguments
  containing spaces are not preserved. Callers needing complex quoting should be
  redesigned around structured tool inputs rather than a shell string.
  """

  alias MiniAgent.Tools.Sandbox

  @default_whitelist ~w[ls cat grep find wc head tail echo mix git rg fd bat]
  @max_output_bytes 4_000

  @doc "Run a shell command if it is in the allowed whitelist."
  @spec run(map(), String.t()) :: String.t()
  def run(%{"command" => cmd}, workspace) do
    whitelist = Application.get_env(:mini_agent, :shell_whitelist, @default_whitelist)
    allowed_set = MapSet.new(whitelist)

    case String.split(cmd, " ", trim: true) do
      [] ->
        "Error: empty command"

      [bin | args] ->
        cond do
          not MapSet.member?(allowed_set, bin) ->
            allowed_str = whitelist |> Enum.sort() |> Enum.join(", ")
            "Error: '#{bin}' not in whitelist: #{allowed_str}"

          Enum.any?(args, &Sandbox.arg_escapes?(&1, workspace)) ->
            "Error: argument path outside workspace"

          true ->
            execute(bin, args, workspace)
        end
    end
  end

  def run(_input, _workspace), do: "Error: missing required parameter 'command'"

  @spec execute(String.t(), list(String.t()), String.t()) :: String.t()
  defp execute(bin, args, workspace) do
    case System.cmd(bin, args, stderr_to_stdout: true, cd: workspace) do
      {output, 0} -> :binary.copy(String.slice(output, 0, @max_output_bytes))
      {output, code} -> "Exit #{code}:\n#{String.slice(output, 0, @max_output_bytes)}"
    end
  rescue
    e -> "Execution error: #{Exception.message(e)}"
  end
end
