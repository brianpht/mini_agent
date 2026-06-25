defmodule MiniAgent.LLM.Behaviour do
  @moduledoc "Behaviour contract for LLM client implementations. Allows Mox-based test doubles."

  @doc "Send messages to the LLM. Returns {:ok, response_map} | {:error, reason}."
  @callback chat(messages :: list(map()), opts :: keyword()) ::
              {:ok, map()} | {:error, String.t()}

  @doc """
  Streaming chat. Calls on_chunk for each text delta as it arrives.
  Returns {:ok, response_map} in the same format as chat/2 when complete.
  """
  @callback chat_stream(
              messages :: list(map()),
              on_chunk :: (String.t() -> :ok),
              opts :: keyword()
            ) :: {:ok, map()} | {:error, String.t()}

  @doc "Extract concatenated text from a response map."
  @callback extract_text(response :: map()) :: String.t()

  @doc "Extract tool_use content blocks from a response map."
  @callback extract_tool_calls(response :: map()) :: list(map())

  @doc "Return total tokens consumed (input + output) from a response map."
  @callback usage(response :: map()) :: non_neg_integer()
end
