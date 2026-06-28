defmodule MiniAgent.Tools.Sandbox do
  @moduledoc """
  Shared path-confinement logic for workspace-sandboxed tools.

  A path is permitted only if, after being expanded against the workspace root
  (never the OS cwd) and having its deepest existing ancestor resolved through
  any symlinks, it resolves to the workspace root itself or a descendant of it.

  This is the single source of truth used by both `MiniAgent.Tools.FileTool` and
  `MiniAgent.Tools.ShellTool`, so the sandbox boundary is defined exactly once.
  """

  # Linux ELOOP threshold; bounds symlink-chain resolution against cycles.
  @max_link_hops 40

  @doc """
  Confine `path` to `workspace`.

  Relative paths are expanded against the workspace root, not the OS cwd, so a
  relative `../` cannot silently escape. Symlinks are followed before the
  boundary check so an in-workspace symlink cannot point outside.

  Returns `{:ok, absolute_path}` (suitable to hand to `File.*`) when the path is
  inside the workspace, or `{:error, :outside_workspace}` otherwise.
  """
  @spec confine(String.t(), String.t()) :: {:ok, String.t()} | {:error, :outside_workspace}
  def confine(path, workspace) do
    root = Path.expand(workspace)
    expanded = Path.expand(path, root)

    if within?(real_path(expanded), real_path(root)) do
      {:ok, expanded}
    else
      {:error, :outside_workspace}
    end
  end

  @doc """
  True when a shell argument would reach outside the workspace.

  Only arguments that look like paths (absolute, or containing a `..` segment)
  are resolved; ordinary flags and patterns are treated as safe.
  """
  @spec arg_escapes?(String.t(), String.t()) :: boolean()
  def arg_escapes?(arg, workspace) do
    if path_like?(arg) do
      match?({:error, :outside_workspace}, confine(arg, workspace))
    else
      false
    end
  end

  @spec path_like?(String.t()) :: boolean()
  defp path_like?(arg) do
    Path.type(arg) == :absolute or ".." in Path.split(arg)
  end

  @spec within?(String.t(), String.t()) :: boolean()
  defp within?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  # Canonicalize `path` by resolving symlinks on its deepest existing ancestor.
  # Non-existent leaves (e.g. a file about to be written) are preserved so write
  # paths can still be validated. Bounded by @max_link_hops to avoid cycles.
  @spec real_path(String.t()) :: String.t()
  defp real_path(path), do: real_path(path, @max_link_hops)

  @spec real_path(String.t(), non_neg_integer()) :: String.t()
  defp real_path(path, 0), do: path

  defp real_path(path, hops) do
    parent = Path.dirname(path)

    if parent == path do
      path
    else
      resolve_leaf(real_path(parent, hops), Path.basename(path), hops)
    end
  end

  # Given an already-canonical parent, resolve a single trailing component,
  # following it through one symlink hop if present.
  @spec resolve_leaf(String.t(), String.t(), non_neg_integer()) :: String.t()
  defp resolve_leaf(real_parent, base, hops) do
    candidate = Path.join(real_parent, base)

    case :file.read_link_all(candidate) do
      {:ok, target} -> real_path(absolutize(real_parent, List.to_string(target)), hops - 1)
      {:error, _} -> candidate
    end
  end

  @spec absolutize(String.t(), String.t()) :: String.t()
  defp absolutize(real_parent, target) do
    if Path.type(target) == :absolute, do: target, else: Path.join(real_parent, target)
  end
end
