defmodule MiniAgent.Tools do
  @moduledoc "Tool registry, Anthropic schema definitions, and dispatcher."

  alias MiniAgent.Tools.{Context, FileTool, ShellTool}

  @type tool_name :: String.t()
  @type tool_input :: map()
  @type tool_result :: String.t()

  @doc "Tool schema list sent with each LLM request."
  @spec definitions() :: list(map())
  def definitions do
    [
      tool(
        "read_file",
        "Read file contents (up to 4000 bytes per call). Use the optional offset parameter to page through large files.",
        %{
          path: %{type: "string", description: "file path"},
          offset: %{type: "integer", description: "byte offset to start reading from (default 0)"}
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
      ),
      tool(
        "delegate",
        "Decompose a complex task into parallel sub-agents and synthesize results. Use when the task has independent sub-problems that can be explored concurrently.",
        %{
          task: %{type: "string", description: "the complex task to decompose and delegate"}
        },
        ["task"]
      )
    ]
  end

  @doc "Tool schema list for sub-agents. Excludes delegate to prevent recursive fan-out."
  @spec safe_definitions() :: list(map())
  def safe_definitions do
    Enum.reject(definitions(), &(&1.name == "delegate"))
  end

  @doc """
  Dispatch tool execution by name. Uses static pattern matching - no apply/3.

  The `ctx` parameter carries the calling agent's permission mode and sandbox
  workspace. Both are propagated to sub-agents via the delegate clause so that
  sub-agents always inherit the parent's context rather than re-reading globals.
  """
  @spec execute(tool_name(), tool_input(), Context.t()) :: tool_result()
  def execute("read_file", input, %Context{workspace: ws} = ctx) do
    result = FileTool.read_file(input, ws)
    emit(:telemetry, "read_file", ctx.session_id)
    result
  end

  def execute("list_dir", input, %Context{workspace: ws} = ctx) do
    result = FileTool.list_dir(input, ws)
    emit(:telemetry, "list_dir", ctx.session_id)
    result
  end

  def execute("write_file", input, %Context{workspace: ws} = ctx) do
    result = FileTool.write_file(input, ws)
    emit(:telemetry, "write_file", ctx.session_id)
    result
  end

  def execute("shell", input, %Context{workspace: ws} = ctx) do
    result = ShellTool.run(input, ws)
    emit(:telemetry, "shell", ctx.session_id)
    result
  end

  def execute("delegate", %{"task" => task}, %Context{mode: mode, workspace: ws} = ctx) do
    emit(:telemetry, "delegate", ctx.session_id)
    MiniAgent.Orchestrator.run(task, mode: mode, workspace: ws)
  end

  def execute(name, _input, ctx) do
    emit(:telemetry, name, ctx.session_id)
    "Error: unknown tool '#{name}'"
  end

  @doc "True for tools that can modify state or execute code."
  @spec dangerous?(tool_name()) :: boolean()
  def dangerous?("write_file"), do: true
  def dangerous?("shell"), do: true
  def dangerous?("delegate"), do: false
  def dangerous?(_), do: false

  @spec tool(String.t(), String.t(), map(), list(String.t())) :: map()
  defp tool(name, desc, props, required) do
    %{
      name: name,
      description: desc,
      input_schema: %{type: "object", properties: props, required: required}
    }
  end

  @spec emit(:telemetry, tool_name(), String.t() | nil) :: :ok
  defp emit(:telemetry, name, session_id) do
    :telemetry.execute(
      [:mini_agent, :tool, :executed],
      %{count: 1},
      %{name: name, session_id: session_id}
    )
  end
end
