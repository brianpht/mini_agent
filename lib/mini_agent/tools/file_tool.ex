defmodule MiniAgent.Tools.FileTool do
  @moduledoc """
  File system tools - read, write, list directory. All paths sandboxed to workspace.

  The workspace root is passed explicitly by the caller (read once at the agent
  boundary) so that concurrent sub-agents can never interfere via a shared
  Application env key.
  """

  @max_read_bytes 4_000

  @doc "Read file contents up to #{@max_read_bytes} bytes starting at the given byte offset."
  @spec read_file(map(), String.t()) :: String.t()
  def read_file(%{"path" => path} = input, workspace) do
    offset = max(0, Map.get(input, "offset", 0))

    with :ok <- check_path(path, workspace),
         {:ok, content} <- File.read(path) do
      size = byte_size(content)
      start = min(offset, size)
      len = min(@max_read_bytes, size - start)
      chunk = :binary.copy(binary_part(content, start, len))
      remaining = size - start - len

      if remaining > 0 do
        chunk <>
          "\n[truncated - #{remaining} bytes remaining, use offset: #{start + len}]"
      else
        chunk
      end
    else
      {:error, :outside_workspace} -> "Error: path outside workspace"
      {:error, reason} -> "Error reading file: #{reason}"
    end
  end

  def read_file(_input, _workspace), do: "Error: missing required parameter 'path'"

  @doc "List files in directory."
  @spec list_dir(map(), String.t()) :: String.t()
  def list_dir(%{"path" => path}, workspace) do
    with :ok <- check_path(path, workspace),
         {:ok, files} <- File.ls(path) do
      Enum.join(files, "\n")
    else
      {:error, :outside_workspace} -> "Error: path outside workspace"
      {:error, reason} -> "Error listing directory: #{reason}"
    end
  end

  def list_dir(_input, _workspace), do: "Error: missing required parameter 'path'"

  @doc "Write content to file."
  @spec write_file(map(), String.t()) :: String.t()
  def write_file(%{"path" => path, "content" => content}, workspace) do
    with :ok <- check_path(path, workspace),
         :ok <- File.write(path, content) do
      "Wrote #{byte_size(content)} bytes to #{path}"
    else
      {:error, :outside_workspace} -> "Error: path outside workspace"
      {:error, reason} -> "Error writing file: #{reason}"
    end
  end

  def write_file(_input, _workspace),
    do: "Error: missing required parameters 'path' and/or 'content'"

  @spec check_path(String.t(), String.t()) :: :ok | {:error, :outside_workspace}
  defp check_path(path, workspace) do
    expanded = Path.expand(path)

    if String.starts_with?(expanded, workspace) do
      :ok
    else
      {:error, :outside_workspace}
    end
  end
end
