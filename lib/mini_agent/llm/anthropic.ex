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

    # Agent accumulates StreamParser state across chunks.
    # The into: callback calls on_chunk directly (in the calling process),
    # then updates the Agent with the new parser state.
    # Agent is stopped in the after block to prevent leaks even if Req.post raises.
    {:ok, agent} = Agent.start_link(fn -> StreamParser.new() end)

    result =
      try do
        Req.post(@url,
          json: body,
          headers: stream_headers(),
          receive_timeout: 120_000,
          into: fn {:data, data}, {req, resp} ->
            chunks = Agent.get_and_update(agent, &collect_sse_chunks(data, &1))
            Enum.each(chunks, on_chunk)
            {:cont, {req, resp}}
          end
        )
      rescue
        e ->
          Agent.stop(agent)
          reraise e, __STACKTRACE__
      end

    final = Agent.get(agent, & &1)
    Agent.stop(agent)

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
  # Returns {text_chunks, new_parser} for use with Agent.get_and_update.
  # on_chunk is called from the into: callback (calling process), not from Agent process.
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
      {"x-api-key", System.fetch_env!("ANTHROPIC_API_KEY")},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]
  end

  @spec stream_headers() :: list({String.t(), String.t()})
  defp stream_headers do
    [
      {"x-api-key", System.fetch_env!("ANTHROPIC_API_KEY")},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"}
    ]
  end

  @spec maybe_put(map(), atom(), term()) :: map()
  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end
