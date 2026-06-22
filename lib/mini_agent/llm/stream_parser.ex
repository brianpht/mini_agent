defmodule MiniAgent.LLM.StreamParser do
  @moduledoc """
  Pure parser for Anthropic Server-Sent Events streaming responses.

  Anthropic emits these event types:
    message_start        - contains input token count
    content_block_start  - opens a text or tool_use block
    content_block_delta  - text_delta or input_json_delta chunk
    content_block_stop   - closes the current block
    message_delta        - contains output token count and stop_reason
    message_stop         - end of stream

  call handle_line/2 for each raw SSE line. It returns {new_state, effect}
  where effect is {:text, chunk} when a text delta should be printed, or :none.

  call to_response/1 at the end to get a map compatible with the non-streaming
  Anthropic response format so the agent loop can reuse the same logic.
  """

  defstruct text: "",
            tool_calls: [],
            current_tool: nil,
            current_json: "",
            usage: 0,
            stop_reason: nil

  @type t :: %__MODULE__{
          text: String.t(),
          tool_calls: list(map()),
          current_tool: map() | nil,
          current_json: String.t(),
          usage: non_neg_integer(),
          stop_reason: String.t() | nil
        }

  @type effect :: {:text, String.t()} | :none

  @doc "Return a fresh parser state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Process one raw SSE line. Returns {updated_state, effect}.
  effect is {:text, chunk} when a text delta is ready for immediate output,
  or :none for all other events.
  """
  @spec handle_line(t(), String.t()) :: {t(), effect()}
  def handle_line(state, "data: " <> json) do
    case Jason.decode(json) do
      {:ok, event} -> handle_event(state, event)
      {:error, _} -> {state, :none}
    end
  end

  def handle_line(state, _other), do: {state, :none}

  @doc "Convert accumulated parser state to an Anthropic-compatible response map."
  @spec to_response(t()) :: map()
  def to_response(%__MODULE__{} = s) do
    text_block =
      if s.text != "" do
        [%{"type" => "text", "text" => s.text}]
      else
        []
      end

    tool_blocks =
      Enum.map(s.tool_calls, fn t ->
        %{
          "type" => "tool_use",
          "id" => t["id"],
          "name" => t["name"],
          "input" => t["input"]
        }
      end)

    %{
      "content" => text_block ++ tool_blocks,
      "usage" => %{"input_tokens" => 0, "output_tokens" => s.usage},
      "stop_reason" => s.stop_reason
    }
  end

  # --- private event handlers ---

  @spec handle_event(t(), map()) :: {t(), effect()}

  # opening a tool_use block: capture id and name, reset json accumulator
  defp handle_event(state, %{
         "type" => "content_block_start",
         "content_block" => %{"type" => "tool_use", "id" => id, "name" => name}
       }) do
    tool = %{"id" => id, "name" => name, "input" => %{}}
    {%{state | current_tool: tool, current_json: ""}, :none}
  end

  defp handle_event(state, %{"type" => "content_block_start"}), do: {state, :none}

  # text delta: append to accumulated text and signal caller to print
  defp handle_event(state, %{
         "type" => "content_block_delta",
         "delta" => %{"type" => "text_delta", "text" => chunk}
       }) do
    {%{state | text: state.text <> chunk}, {:text, chunk}}
  end

  # tool input json: accumulate partial JSON (do not parse yet)
  defp handle_event(state, %{
         "type" => "content_block_delta",
         "delta" => %{"type" => "input_json_delta", "partial_json" => part}
       }) do
    {%{state | current_json: state.current_json <> part}, :none}
  end

  defp handle_event(state, %{"type" => "content_block_delta"}), do: {state, :none}

  # closing a tool block: parse accumulated JSON and finalize the tool entry
  defp handle_event(%{current_tool: tool} = state, %{"type" => "content_block_stop"})
       when not is_nil(tool) do
    input =
      case Jason.decode(state.current_json) do
        {:ok, map} -> map
        {:error, _} -> %{}
      end

    finished = Map.put(tool, "input", input)

    new_state = %{
      state
      | tool_calls: state.tool_calls ++ [finished],
        current_tool: nil,
        current_json: ""
    }

    {new_state, :none}
  end

  defp handle_event(state, %{"type" => "content_block_stop"}), do: {state, :none}

  # input token count arrives in message_start
  defp handle_event(state, %{"type" => "message_start", "message" => %{"usage" => u}}) do
    input_tokens = u["input_tokens"] || 0
    {%{state | usage: state.usage + input_tokens}, :none}
  end

  # output token count and stop_reason arrive in message_delta
  defp handle_event(state, %{"type" => "message_delta"} = ev) do
    output_tokens = get_in(ev, ["usage", "output_tokens"]) || 0
    stop_reason = get_in(ev, ["delta", "stop_reason"])
    {%{state | usage: state.usage + output_tokens, stop_reason: stop_reason}, :none}
  end

  defp handle_event(state, _ignored), do: {state, :none}
end
