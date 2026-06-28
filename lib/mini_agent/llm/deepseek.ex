defmodule MiniAgent.LLM.DeepSeek do
  @moduledoc """
  DeepSeek API client (OpenAI-compatible endpoint). Implements MiniAgent.LLM.Behaviour.

  Translates between the internal Anthropic-like message format used by the agent loop
  and the OpenAI Chat Completions format expected by DeepSeek. All format conversions
  are confined to this module - the agent loop requires no changes.

  Streaming: chat_stream/3 uses real token-by-token SSE streaming via the OpenAI
  streaming format (stream: true, data: [DONE] terminator). Parsed by
  MiniAgent.LLM.DeepSeekStreamParser. An ETS table carries parser state across
  Req :into callbacks.

  Required env var: DEEPSEEK_API_KEY
  """

  @behaviour MiniAgent.LLM.Behaviour

  alias MiniAgent.LLM.DeepSeekStreamParser
  alias MiniAgent.LLM.Error

  @url "https://api.deepseek.com/v1/chat/completions"
  @model Application.compile_env!(:mini_agent, :model)
  @max_tokens Application.compile_env!(:mini_agent, :max_tokens)

  @impl MiniAgent.LLM.Behaviour
  @spec chat(list(map()), keyword()) :: {:ok, map()} | {:error, MiniAgent.LLM.Error.t()}
  def chat(messages, opts \\ []) do
    oai_messages = to_openai_messages(messages, opts[:system])
    oai_tools = opts[:tools] && Enum.map(opts[:tools], &to_openai_tool/1)

    body =
      %{model: @model, max_tokens: @max_tokens, messages: oai_messages}
      |> maybe_put(:tools, oai_tools)

    case Req.post(@url, json: body, headers: headers(), receive_timeout: 60_000) do
      {:ok, %{status: 200, body: resp}} -> {:ok, normalize_response(resp)}
      {:ok, %{status: s, body: _e}} -> {:error, Error.classify_http(s)}
      {:error, reason} -> {:error, Error.classify_network(reason)}
    end
  end

  @impl MiniAgent.LLM.Behaviour
  @spec chat_stream(list(map()), (String.t() -> :ok), keyword()) ::
          {:ok, map()} | {:error, MiniAgent.LLM.Error.t()}
  def chat_stream(messages, on_chunk, opts \\ []) when is_function(on_chunk, 1) do
    oai_messages = to_openai_messages(messages, opts[:system])
    oai_tools = opts[:tools] && Enum.map(opts[:tools], &to_openai_tool/1)

    body =
      %{model: @model, max_tokens: @max_tokens, messages: oai_messages, stream: true}
      |> maybe_put(:tools, oai_tools)

    # ETS table accumulates DeepSeekStreamParser state across SSE chunks.
    # Using ETS instead of Agent avoids spawning a GenServer per streaming call.
    # on_chunk is called in the into: callback (calling process), not from a
    # separate process. ETS is auto-cleaned if the owning process crashes.
    tid = :ets.new(:deepseek_stream, [:set, :private])
    :ets.insert(tid, {:parser, DeepSeekStreamParser.new()})

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
      {:ok, %{status: 200}} -> {:ok, DeepSeekStreamParser.to_response(final)}
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

  # ---------------------------------------------------------------------------
  # Response normalization: OpenAI -> internal Anthropic-like format
  # ---------------------------------------------------------------------------

  @spec normalize_response(map()) :: map()
  defp normalize_response(%{"choices" => [choice | _], "usage" => usage} = _resp) do
    message = choice["message"] || %{}
    content_blocks = build_content_blocks(message)

    %{
      "content" => content_blocks,
      "usage" => %{
        "input_tokens" => usage["prompt_tokens"] || 0,
        "output_tokens" => usage["completion_tokens"] || 0
      }
    }
  end

  defp normalize_response(_),
    do: %{"content" => [], "usage" => %{"input_tokens" => 0, "output_tokens" => 0}}

  @spec build_content_blocks(map()) :: list(map())
  defp build_content_blocks(message) do
    text_blocks =
      case message["content"] do
        text when is_binary(text) and text != "" -> [%{"type" => "text", "text" => text}]
        _ -> []
      end

    tool_blocks =
      case message["tool_calls"] do
        calls when is_list(calls) -> Enum.map(calls, &to_tool_use_block/1)
        _ -> []
      end

    text_blocks ++ tool_blocks
  end

  @spec to_tool_use_block(map()) :: map()
  defp to_tool_use_block(%{"id" => id, "function" => %{"name" => name, "arguments" => args}}) do
    input =
      case Jason.decode(args) do
        {:ok, decoded} when is_map(decoded) -> decoded
        _ -> %{}
      end

    %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
  end

  # ---------------------------------------------------------------------------
  # Message translation: internal Anthropic-like format -> OpenAI format
  # ---------------------------------------------------------------------------

  @spec to_openai_messages(list(map()), String.t() | nil) :: list(map())
  defp to_openai_messages(messages, system) do
    system_msg =
      if is_binary(system) and system != "",
        do: [%{"role" => "system", "content" => system}],
        else: []

    converted = Enum.flat_map(messages, &convert_message/1)
    system_msg ++ converted
  end

  @spec convert_message(map()) :: list(map())
  defp convert_message(%{"role" => "assistant", "content" => content}) when is_list(content) do
    text =
      content
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("\n", & &1["text"])

    tool_calls =
      content
      |> Enum.filter(&(&1["type"] == "tool_use"))
      |> Enum.map(&to_openai_tool_call/1)

    msg =
      %{"role" => "assistant"}
      |> maybe_put("content", if(text != "", do: text, else: nil))
      |> maybe_put("tool_calls", if(tool_calls != [], do: tool_calls, else: nil))

    [msg]
  end

  defp convert_message(%{"role" => "user", "content" => content}) when is_list(content) do
    tool_results = Enum.filter(content, &(&1["type"] == "tool_result"))

    if tool_results != [] do
      # Convert each tool result to a role:tool message (OpenAI format)
      tool_messages =
        Enum.map(tool_results, fn block ->
          %{
            "role" => "tool",
            "tool_call_id" => block["tool_use_id"],
            "content" => block["content"] || ""
          }
        end)

      # Also emit any accompanying text blocks (e.g. iteration nudge) as a user message
      text_blocks = Enum.filter(content, &(&1["type"] == "text"))

      text_messages =
        if text_blocks != [] do
          text = Enum.map_join(text_blocks, "\n", & &1["text"])
          [%{"role" => "user", "content" => text}]
        else
          []
        end

      tool_messages ++ text_messages
    else
      # Plain user message with mixed content - extract text
      text =
        content
        |> Enum.filter(&(&1["type"] == "text"))
        |> Enum.map_join("\n", & &1["text"])

      [%{"role" => "user", "content" => text}]
    end
  end

  defp convert_message(msg), do: [msg]

  @spec to_openai_tool_call(map()) :: map()
  defp to_openai_tool_call(%{"id" => id, "name" => name, "input" => input}) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{
        "name" => name,
        "arguments" => Jason.encode!(input)
      }
    }
  end

  # ---------------------------------------------------------------------------
  # Tool definition translation: Anthropic schema -> OpenAI function schema
  # ---------------------------------------------------------------------------

  @spec to_openai_tool(map()) :: map()
  defp to_openai_tool(%{name: name, description: desc, input_schema: schema}) do
    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => desc,
        "parameters" => schema
      }
    }
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Parses all SSE lines in one data chunk.
  # Returns {text_chunks, new_parser}. Called from the Req :into callback
  # (calling process) to update the ETS accumulator with new parser state.
  @spec collect_sse_chunks(String.t(), DeepSeekStreamParser.t()) ::
          {list(String.t()), DeepSeekStreamParser.t()}
  defp collect_sse_chunks(data, parser) do
    {final_parser, chunks_rev} =
      data
      |> String.split("\n")
      |> Enum.reduce({parser, []}, fn line, {acc_parser, acc_chunks} ->
        {new_parser, effect} = DeepSeekStreamParser.handle_line(acc_parser, String.trim(line))

        new_chunks =
          case effect do
            {:text, chunk} -> [chunk | acc_chunks]
            :none -> acc_chunks
          end

        {new_parser, new_chunks}
      end)

    {Enum.reverse(chunks_rev), final_parser}
  end

  @spec headers() :: list({String.t(), String.t()})
  defp headers do
    [
      {"authorization", "Bearer #{api_key()}"},
      {"content-type", "application/json"}
    ]
  end

  @spec stream_headers() :: list({String.t(), String.t()})
  defp stream_headers do
    [
      {"authorization", "Bearer #{api_key()}"},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"}
    ]
  end

  # Read API key once, cache in :persistent_term for subsequent requests.
  @spec api_key() :: String.t()
  defp api_key do
    key = {:mini_agent, :deepseek_api_key}

    try do
      :persistent_term.get(key)
    rescue
      ArgumentError ->
        val = System.fetch_env!("DEEPSEEK_API_KEY")
        :persistent_term.put(key, val)
        val
    end
  end

  @spec maybe_put(map(), term(), term()) :: map()
  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end
