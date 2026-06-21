defmodule MiniAgent.Tools.FileTools do
  @moduledoc "File system tools - read, write, list directory. All paths sandboxed to workspace."

  @max_read_bytes 4_000
  @workspace Application.compile_env!(:mini_agent, :workspace)

  @doc "Read file contents up to #{@max_read_bytes} bytes."
  @spec read_file(map()) :: String.t()
  def read_file(%{"path" => path}) do
    with :ok <- check_path(path),
         {:ok, content} <- File.read(path) do
      :binary.copy(String.slice(content, 0, @max_read_bytes))
    else
      {:error, :outside_workspace} -> "Error: path outside workspace"
      {:error, reason} -> "Error reading file: #{reason}"
    end
  end

  @doc "List files in directory."
  @spec list_dir(map()) :: String.t()
  def list_dir(%{"path" => path}) do
    with :ok <- check_path(path),
         {:ok, files} <- File.ls(path) do
      Enum.join(files, "\n")
    else
      {:error, :outside_workspace} -> "Error: path outside workspace"
      {:error, reason} -> "Error listing directory: #{reason}"
    end
  end

  @doc "Write content to file."
  @spec write_file(map()) :: String.t()
  def write_file(%{"path" => path, "content" => content}) do
    with :ok <- check_path(path),
         :ok <- File.write(path, content) do
      "Wrote #{byte_size(content)} bytes to #{path}"
    else
      {:error, :outside_workspace} -> "Error: path outside workspace"
      {:error, reason} -> "Error writing file: #{reason}"
    end
  end

  @spec check_path(String.t()) :: :ok | {:error, :outside_workspace}
  defp check_path(path) do
    expanded = Path.expand(path)

    if String.starts_with?(expanded, @workspace) do
      :ok
    else
      {:error, :outside_workspace}
    end
  end
end
