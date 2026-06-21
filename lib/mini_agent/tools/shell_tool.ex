defmodule MiniAgent.Tools.ShellTool do
  @moduledoc "Runs whitelisted shell commands sandboxed to workspace directory."

  @allowed_commands MapSet.new(~w(ls cat grep find wc head tail echo mix git))
  @max_output_bytes 4_000
  @workspace Application.compile_env!(:mini_agent, :workspace)

  @doc "Run a shell command if it is in the allowed whitelist."
  @spec run(map()) :: String.t()
  def run(%{"command" => cmd}) do
    case String.split(cmd, " ", trim: true) do
      [] ->
        "Error: empty command"

      [bin | args] ->
        if MapSet.member?(@allowed_commands, bin) do
          execute(bin, args)
        else
          allowed =
            @allowed_commands
            |> MapSet.to_list()
            |> Enum.sort()
            |> Enum.join(", ")

          "Error: '#{bin}' not in whitelist: #{allowed}"
        end
    end
  end

  @spec execute(String.t(), list(String.t())) :: String.t()
  defp execute(bin, args) do
    case System.cmd(bin, args, stderr_to_stdout: true, cd: @workspace) do
      {output, 0} -> :binary.copy(String.slice(output, 0, @max_output_bytes))
      {output, code} -> "Exit #{code}:\n#{String.slice(output, 0, @max_output_bytes)}"
    end
  rescue
    e -> "Execution error: #{Exception.message(e)}"
  end
end
