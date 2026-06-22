defmodule MiniAgent.LLM.DeepSeek do
  @moduledoc """
  DeepSeek API client (OpenAI-compatible endpoint). Implements MiniAgent.LLMBehaviour.

  Translates between the internal Anthropic-like message format used by the agent loop
  and the OpenAI Chat Completions format expected by DeepSeek. All format conversions
  are confined to this module - the agent loop requires no changes.

  Required env var: DEEPSEEK_API_KEY
  """

  @behaviour MiniAgent.LLMBehaviour

  @url "https://api.deepseek.com/v1/chat/completions"
  @model Application.compile_env!(:mini_agent, :model)
  @max_tokens Application.compile_env!(:mini_agent, :max_tokens)

  @impl MiniAgent.LLMBehaviour
  @spec chat(list(map()), keyword()) :: {:ok, map()} | {:error, String.t()}
  def chat(messages, opts \\ []) do
    oai_messages = to_openai_messages(messages, opts[:system])
    oai_tools = opts[:tools] && Enum.map(opts[:tools], &to_openai_tool/1)

    body =
      %{model: @model, max_tokens: @max_tokens, messages: oai_messages}
      |> maybe_put(:tools, oai_tools)

    case Req.post(@url, json: body, headers: headers(), receive_timeout: 60_000) do
      {:ok, %{status: 200, body: resp}} -> {:ok, normalize_response(resp)}
      {:ok, %{status: s, body: e}} -> {:error, "HTTP #{s}: #{inspect(e)}"}
      {:error, reason} -> {:error, "Network: #{inspect(reason)}"}
    end
  end

  @impl MiniAgent.LLMBehaviour
  @spec extract_text(map()) :: String.t()
  def extract_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("\n", & &1["text"])
  end

  def extract_text(_), do: ""

  @impl MiniAgent.LLMBehaviour
  @spec extract_tool_calls(map()) :: list(map())
  def extract_tool_calls(%{"content" => content}) when is_list(content) do
    Enum.filter(content, &(&1["type"] == "tool_use"))
  end

  def extract_tool_calls(_), do: []

  @impl MiniAgent.LLMBehaviour
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
    # Tool result blocks -> individual role:tool messages
    tool_results = Enum.filter(content, &(&1["type"] == "tool_result"))

    if tool_results != [] do
      Enum.map(tool_results, fn block ->
        %{
          "role" => "tool",
          "tool_call_id" => block["tool_use_id"],
          "content" => block["content"] || ""
        }
      end)
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

  @spec headers() :: list({String.t(), String.t()})
  defp headers do
    [
      {"authorization", "Bearer #{System.fetch_env!("DEEPSEEK_API_KEY")}"},
      {"content-type", "application/json"}
    ]
  end

  @spec maybe_put(map(), term(), term()) :: map()
  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end
