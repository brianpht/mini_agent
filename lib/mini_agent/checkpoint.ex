defmodule MiniAgent.Checkpoint do
  @moduledoc """
  Persist and restore agent state to/from disk as JSON.

  Each session has one file: <dir>/<session_id>.json. Saving overwrites the
  current snapshot (latest wins). An append-only .history file tracks iteration
  timestamps for audit.

  Only serializable fields are persisted. Transient per-iteration fields
  (stream_callback, tool_calls, last) are excluded and reset on resume.

  The checkpoint directory defaults to .mini_agent/checkpoints and is
  configurable via Application env :mini_agent, :checkpoint_dir.
  """

  alias MiniAgent.Budget

  @version 1

  @type session_id :: String.t()

  @type summary :: %{
          session_id: session_id(),
          task: String.t(),
          iterations: non_neg_integer(),
          done: boolean(),
          saved_at: String.t(),
          tokens: non_neg_integer()
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Generate a lexicographically sortable session ID (unix_ts-hex6).

  Accepts an optional `now_unix` integer (seconds since Unix epoch) for
  deterministic generation in tests. When nil, uses
  `:erlang.system_time(:second)` - wall-second clock (not monotonic; may jump
  on NTP adjustment; suitable for session IDs and audit, not duration measurement).
  """
  @spec new_session_id(non_neg_integer() | nil) :: session_id()
  def new_session_id(now_unix \\ nil) do
    ts = now_unix || :erlang.system_time(:second)
    rand = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
    "#{ts}-#{rand}"
  end

  @doc """
  Persist a snapshot of state to disk. Returns the session_id used.
  Overwrites any previous snapshot for the same session_id.
  """
  @spec save(MiniAgent.State.t()) :: session_id()
  def save(%MiniAgent.State{} = state) do
    sid = state.session_id || new_session_id()

    snapshot = %{
      "version" => @version,
      "session_id" => sid,
      "saved_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "task" => state.task,
      "mode" => Atom.to_string(state.mode),
      "workspace" => state.workspace,
      "iterations" => state.iterations,
      "done" => state.done,
      "output" => state.output,
      "budget" => %{
        "used" => state.budget.used,
        "limit" => state.budget.limit
      },
      "messages" => sanitize_messages(state.messages)
    }

    json = Jason.encode!(snapshot, pretty: true)
    path = checkpoint_path(sid)
    File.write!(path, json)
    append_history(sid, state.iterations)

    sid
  end

  @doc """
  Load a previously saved session. Returns {:ok, state} on success where
  state is ready to be passed directly into the agent loop, or
  {:error, reason} if the file is missing, unreadable, or version-incompatible.
  """
  @spec load(session_id()) :: {:ok, MiniAgent.State.t()} | {:error, String.t()}
  def load(session_id) do
    with {:ok, json} <- File.read(checkpoint_path(session_id)),
         {:ok, data} <- Jason.decode(json),
         :ok <- check_version(data),
         {:ok, mode} <- parse_mode(data["mode"]),
         {:ok, messages} <- restore_messages(data["messages"]) do
      state = %MiniAgent.State{
        session_id: data["session_id"],
        task: data["task"],
        mode: mode,
        workspace: data["workspace"] || Application.get_env(:mini_agent, :workspace, File.cwd!()),
        iterations: data["iterations"],
        done: data["done"],
        output: data["output"],
        budget: %Budget{
          used: data["budget"]["used"],
          limit: data["budget"]["limit"]
        },
        messages: messages,
        llm_module: Application.fetch_env!(:mini_agent, :llm_module),
        tool_calls: [],
        last: nil,
        stream_callback: nil
      }

      {:ok, state}
    else
      {:error, :enoent} -> {:error, "session not found: #{session_id}"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} when is_atom(reason) -> {:error, "file error: #{reason}"}
      {:error, %Jason.DecodeError{} = e} -> {:error, "JSON decode error: #{Exception.message(e)}"}
    end
  end

  # Parse the persisted mode string into a known atom. Avoids String.to_existing_atom
  # raising on a corrupt or hand-edited checkpoint.
  @spec parse_mode(term()) :: {:ok, MiniAgent.Permission.mode()} | {:error, String.t()}
  defp parse_mode("auto"), do: {:ok, :auto}
  defp parse_mode("ask"), do: {:ok, :ask}
  defp parse_mode("readonly"), do: {:ok, :readonly}
  defp parse_mode(other), do: {:error, "invalid mode in checkpoint: #{inspect(other)}"}

  @doc "List saved sessions, most recently saved first."
  @spec list() :: list(summary())
  def list do
    dir = ensure_dir()

    dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.flat_map(&summarize(Path.basename(&1, ".json")))
    |> Enum.sort_by(& &1.saved_at, :desc)
  end

  @doc "Delete a checkpoint and its history file. Always returns :ok."
  @spec delete(session_id()) :: :ok
  def delete(session_id) do
    _ = File.rm(checkpoint_path(session_id))
    _ = File.rm(history_path(session_id))
    :ok
  end

  # ---------------------------------------------------------------------------
  # Path helpers
  # ---------------------------------------------------------------------------

  @spec dir() :: Path.t()
  defp dir do
    Application.get_env(:mini_agent, :checkpoint_dir, ".mini_agent/checkpoints")
  end

  @spec ensure_dir() :: Path.t()
  defp ensure_dir do
    d = dir()
    File.mkdir_p!(d)
    d
  end

  @spec checkpoint_path(session_id()) :: Path.t()
  defp checkpoint_path(session_id), do: Path.join(ensure_dir(), "#{session_id}.json")

  @spec history_path(session_id()) :: Path.t()
  defp history_path(session_id), do: Path.join(dir(), "#{session_id}.history")

  # ---------------------------------------------------------------------------
  # Serialization helpers
  # ---------------------------------------------------------------------------

  @spec check_version(map()) :: :ok | {:error, String.t()}
  defp check_version(%{"version" => v}) when v == @version, do: :ok

  defp check_version(%{"version" => v}),
    do: {:error, "incompatible checkpoint version: #{v} (expected #{@version})"}

  defp check_version(_), do: {:error, "checkpoint missing version field"}

  # Normalize message list to pure string-keyed maps safe for JSON round-trip.
  @spec sanitize_messages(list(map())) :: list(map())
  defp sanitize_messages(messages) do
    Enum.map(messages, fn msg ->
      role = msg["role"] || msg[:role] || "unknown"
      content = msg["content"] || msg[:content]

      %{
        "role" => to_string(role),
        "content" => sanitize_content(content)
      }
    end)
  end

  @spec sanitize_content(term()) :: term()
  defp sanitize_content(content) when is_binary(content), do: content

  defp sanitize_content(content) when is_list(content) do
    Enum.map(content, &stringify_keys/1)
  end

  defp sanitize_content(other), do: other

  @spec stringify_keys(term()) :: term()
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(val), do: val

  # Restore messages keeping string keys - the LLM module already expects them.
  # Rejects the whole checkpoint if any message is missing a role or has nil
  # content, rather than silently feeding malformed turns to the LLM.
  @spec restore_messages(term()) :: {:ok, list(map())} | {:error, String.t()}
  defp restore_messages(messages) when is_list(messages) do
    if Enum.all?(messages, &valid_message?/1) do
      {:ok,
       Enum.map(messages, fn msg -> %{"role" => msg["role"], "content" => msg["content"]} end)}
    else
      {:error, "checkpoint contains malformed messages (missing role or content)"}
    end
  end

  defp restore_messages(_), do: {:error, "checkpoint messages field is not a list"}

  @spec valid_message?(term()) :: boolean()
  defp valid_message?(%{"role" => role, "content" => content})
       when is_binary(role) and not is_nil(content),
       do: true

  defp valid_message?(_), do: false

  @spec append_history(session_id(), non_neg_integer()) :: :ok
  defp append_history(session_id, iterations) do
    line = "#{DateTime.utc_now() |> DateTime.to_iso8601()} iterations=#{iterations}\n"
    File.write!(history_path(session_id), line, [:append])
    :ok
  end

  # Build a summary map for a single session_id. Returns [] on any read/decode error
  # so flat_map in list/0 simply drops bad entries.
  @spec summarize(session_id()) :: list(summary())
  defp summarize(session_id) do
    with {:ok, json} <- File.read(checkpoint_path(session_id)),
         {:ok, data} <- Jason.decode(json) do
      [
        %{
          session_id: session_id,
          task: String.slice(data["task"] || "", 0, 60),
          iterations: data["iterations"],
          done: data["done"],
          saved_at: data["saved_at"],
          tokens: get_in(data, ["budget", "used"])
        }
      ]
    else
      _ -> []
    end
  end
end
