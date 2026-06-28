defmodule MiniAgent.LLM.Anthropic do
  @moduledoc "Anthropic Claude API client. Implements MiniAgent.LLM.Behaviour."

  @behaviour MiniAgent.LLM.Behaviour

  alias MiniAgent.LLM.AnthropicStreamParser, as: StreamParser
  alias MiniAgent.LLM.Error

  @url "https://api.anthropic.com/v1/messages"
  @model Application.compile_env!(:mini_agent, :model)
  @max_tokens Application.compile_env!(:mini_agent, :max_tokens)

  @impl MiniAgent.LLM.Behaviour
  @spec chat(list(map()), keyword()) :: {:ok, map()} | {:error, MiniAgent.LLM.Error.t()}
  def chat(messages, opts \\ []) do
    body =
      %{model: @model, max_tokens: @max_tokens, messages: messages}
      |> maybe_put(:system, opts[:system])
      |> maybe_put(:tools, opts[:tools])

    case Req.post(@url, json: body, headers: headers(), receive_timeout: 60_000) do
      {:ok, %{status: 200, body: resp}} -> {:ok, resp}
      {:ok, %{status: s, body: _e}} -> {:error, Error.classify_http(s)}
      {:error, reason} -> {:error, Error.classify_network(reason)}
    end
  end

  @impl MiniAgent.LLM.Behaviour
  @spec chat_stream(list(map()), (String.t() -> :ok), keyword()) ::
          {:ok, map()} | {:error, MiniAgent.LLM.Error.t()}
  def chat_stream(messages, on_chunk, opts \\ []) when is_function(on_chunk, 1) do
    body =
      %{model: @model, max_tokens: @max_tokens, messages: messages, stream: true}
      |> maybe_put(:system, opts[:system])
      |> maybe_put(:tools, opts[:tools])

    # ETS table accumulates StreamParser state across SSE chunks.
    # Using ETS instead of Agent avoids spawning a GenServer per streaming call.
    # The into: callback runs in the calling process so it can update the table
    # directly. ETS is auto-cleaned if the owning process crashes.
    tid = :ets.new(:anthropic_stream, [:set, :private])
    :ets.insert(tid, {:parser, StreamParser.new()})

    result =
      Req.post(@url,
        json: body,
        headers: stream_headers(),
        receive_timeout: 120_000,
        into: fn {:data, data}, {req, resp} ->
          [{:parser, parser}] = :ets.lookup(tid, :parser)
          {chunks, new_parser} = collect_sse_chunks(data, parser)
          :ets.insert(tid, {:parser, new_parser})
          Enum.each(chunks, on_chunk)
          {:cont, {req, resp}}
        end
      )

    [{:parser, final}] = :ets.lookup(tid, :parser)
    :ets.delete(tid)

    case result do
      {:ok, %{status: 200}} -> {:ok, StreamParser.to_response(final)}
      {:ok, %{status: s, body: _e}} -> {:error, Error.classify_http(s)}
      {:error, reason} -> {:error, Error.classify_network(reason)}
    end
  end

  @impl MiniAgent.LLM.Behaviour
  @spec extract_text(map()) :: String.t()
  def extract_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("\n", & &1["text"])
  end

  def extract_text(_), do: ""

  @impl MiniAgent.LLM.Behaviour
  @spec extract_tool_calls(map()) :: list(map())
  def extract_tool_calls(%{"content" => content}) when is_list(content) do
    Enum.filter(content, &(&1["type"] == "tool_use"))
  end

  def extract_tool_calls(_), do: []

  @impl MiniAgent.LLM.Behaviour
  @spec usage(map()) :: non_neg_integer()
  def usage(%{"usage" => %{"input_tokens" => i, "output_tokens" => o}}), do: i + o

  def usage(%{"usage" => u}) when is_map(u),
    do: (u["input_tokens"] || 0) + (u["output_tokens"] || 0)

  def usage(_), do: 0

  # --- private ---

  # Parses all SSE lines in one data chunk.
  # Returns {text_chunks, new_parser}. Called from the Req :into callback
  # (calling process) to update the ETS accumulator with new parser state.
  @spec collect_sse_chunks(String.t(), StreamParser.t()) :: {list(String.t()), StreamParser.t()}
  defp collect_sse_chunks(data, parser) do
    {final_parser, chunks_rev} =
      data
      |> String.split("\n")
      |> Enum.reduce({parser, []}, fn line, {acc_parser, acc_chunks} ->
        {new_parser, effect} = StreamParser.handle_line(acc_parser, String.trim(line))

        new_chunks =
          case effect do
            {:text, chunk} -> [chunk | acc_chunks]
            :none -> acc_chunks
          end

        {new_parser, new_chunks}
      end)

    # reverse to preserve order; return {value_for_caller, new_agent_state}
    {Enum.reverse(chunks_rev), final_parser}
  end

  @spec headers() :: list({String.t(), String.t()})
  defp headers do
    [
      {"x-api-key", api_key()},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]
  end

  @spec stream_headers() :: list({String.t(), String.t()})
  defp stream_headers do
    [
      {"x-api-key", api_key()},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"}
    ]
  end

  # Read API key once, cache in :persistent_term for subsequent requests.
  @spec api_key() :: String.t()
  defp api_key do
    key = {:mini_agent, :anthropic_api_key}

    try do
      :persistent_term.get(key)
    rescue
      ArgumentError ->
        val = System.fetch_env!("ANTHROPIC_API_KEY")
        :persistent_term.put(key, val)
        val
    end
  end

  @spec maybe_put(map(), atom(), term()) :: map()
  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end
