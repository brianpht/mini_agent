defmodule MiniAgent.Tools do
  @moduledoc "Tool registry, Anthropic schema definitions, and dispatcher."

  alias MiniAgent.Tools.{FileTools, ShellTool}

  @type tool_name :: String.t()
  @type tool_input :: map()
  @type tool_result :: String.t()

  @doc "Tool schema list sent with each LLM request."
  @spec definitions() :: list(map())
  def definitions do
    [
      tool(
        "read_file",
        "Read file contents",
        %{
          path: %{type: "string", description: "file path"}
        },
        ["path"]
      ),
      tool(
        "list_dir",
        "List files in directory",
        %{
          path: %{type: "string", description: "directory path"}
        },
        ["path"]
      ),
      tool(
        "write_file",
        "Write content to a file",
        %{
          path: %{type: "string", description: "file path"},
          content: %{type: "string", description: "content to write"}
        },
        ["path", "content"]
      ),
      tool(
        "shell",
        "Run a shell command (ls, cat, grep, find, git, mix...)",
        %{
          command: %{type: "string", description: "full command string"}
        },
        ["command"]
      )
    ]
  end

  @doc "Dispatch tool execution by name. Uses static pattern matching - no apply/3."
  @spec execute(tool_name(), tool_input()) :: tool_result()
  def execute("read_file", input) do
    result = FileTools.read_file(input)
    emit(:telemetry, "read_file")
    result
  end

  def execute("list_dir", input) do
    result = FileTools.list_dir(input)
    emit(:telemetry, "list_dir")
    result
  end

  def execute("write_file", input) do
    result = FileTools.write_file(input)
    emit(:telemetry, "write_file")
    result
  end

  def execute("shell", input) do
    result = ShellTool.run(input)
    emit(:telemetry, "shell")
    result
  end

  def execute(name, _input) do
    emit(:telemetry, name)
    "Error: unknown tool '#{name}'"
  end

  @doc "True for tools that can modify state or execute code."
  @spec dangerous?(tool_name()) :: boolean()
  def dangerous?("write_file"), do: true
  def dangerous?("shell"), do: true
  def dangerous?(_), do: false

  @spec tool(String.t(), String.t(), map(), list(String.t())) :: map()
  defp tool(name, desc, props, required) do
    %{
      name: name,
      description: desc,
      input_schema: %{type: "object", properties: props, required: required}
    }
  end

  @spec emit(:telemetry, tool_name()) :: :ok
  defp emit(:telemetry, name) do
    :telemetry.execute([:mini_agent, :tool, :executed], %{count: 1}, %{name: name})
  end
end
