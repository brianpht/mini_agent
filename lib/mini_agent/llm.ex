defmodule MiniAgent.LLM do
  @moduledoc "Anthropic Claude API client. Implements MiniAgent.LLMBehaviour."

  @behaviour MiniAgent.LLMBehaviour

  @url "https://api.anthropic.com/v1/messages"
  @model Application.compile_env!(:mini_agent, :model)
  @max_tokens Application.compile_env!(:mini_agent, :max_tokens)

  @impl MiniAgent.LLMBehaviour
  @spec chat(list(map()), keyword()) :: {:ok, map()} | {:error, String.t()}
  def chat(messages, opts \\ []) do
    body =
      %{model: @model, max_tokens: @max_tokens, messages: messages}
      |> maybe_put(:system, opts[:system])
      |> maybe_put(:tools, opts[:tools])

    case Req.post(@url, json: body, headers: headers(), receive_timeout: 60_000) do
      {:ok, %{status: 200, body: resp}} -> {:ok, resp}
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

  @spec headers() :: list({String.t(), String.t()})
  defp headers do
    [
      {"x-api-key", System.fetch_env!("ANTHROPIC_API_KEY")},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]
  end

  @spec maybe_put(map(), atom(), term()) :: map()
  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end
