defmodule MiniAgent.LLM.DeepSeekStreamParser do
  @moduledoc """
  Pure parser for OpenAI-compatible Server-Sent Events (DeepSeek streaming API).

  OpenAI SSE format differs from Anthropic SSE. Each chunk is a JSON object
  with a "choices" array. Text arrives in choices[0].delta.content. Tool calls
  arrive incrementally via choices[n].delta.tool_calls[index], where each
  index corresponds to one tool call being streamed.

  Typical event sequence:

    data: {"choices":[{"delta":{"role":"assistant","content":""},...}]}
    data: {"choices":[{"delta":{"content":"Hello"},...}]}
    data: {"choices":[{"delta":{"content":" world"},...}]}
    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_x","type":"function",
                       "function":{"name":"read_file","arguments":""}}]},...}]}
    data: {"choices":[{"delta":{"tool_calls":[{"index":0,
                       "function":{"arguments":"{\"path\":"}}]},...}]}
    data: {"choices":[{"delta":{},"finish_reason":"tool_calls",...}],
           "usage":{"prompt_tokens":10,"completion_tokens":5}}
    data: [DONE]

  call handle_line/2 for each raw SSE line. Returns {new_state, effect} where
  effect is {:text, chunk} or :none.

  call to_response/1 to get a map in the internal Anthropic-like format so the
  agent loop and extract_text/extract_tool_calls can be reused unchanged.
  """

  # tool_slots: %{integer() => %{id, name, args_acc :: iodata()}}
  # text and per-slot args_acc accumulate as IO lists (O(1) appends) and are
  # flattened to binaries once in to_response/1, avoiding quadratic rebuilding.
  defstruct text: [],
            tool_slots: %{},
            input_tokens: 0,
            output_tokens: 0,
            stop_reason: nil

  @type t :: %__MODULE__{
          text: iodata(),
          tool_slots: %{non_neg_integer() => map()},
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          stop_reason: String.t() | nil
        }

  @type effect :: {:text, String.t()} | :none

  @doc "Return a fresh parser state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Process one raw SSE line. Returns {updated_state, effect}.
  effect is {:text, chunk} when a text delta is ready for immediate output,
  or :none otherwise.
  Handles the special 'data: [DONE]' terminator gracefully.
  """
  @spec handle_line(t(), String.t()) :: {t(), effect()}
  def handle_line(state, "data: [DONE]"), do: {state, :none}

  def handle_line(state, "data: " <> json) do
    case Jason.decode(json) do
      {:ok, event} -> handle_event(state, event)
      {:error, _} -> {state, :none}
    end
  end

  def handle_line(state, _other), do: {state, :none}

  @doc "Convert accumulated parser state to an internal Anthropic-like response map."
  @spec to_response(t()) :: map()
  def to_response(%__MODULE__{} = s) do
    text = IO.iodata_to_binary(s.text)

    text_block =
      if text != "" do
        [%{"type" => "text", "text" => text}]
      else
        []
      end

    tool_blocks =
      s.tool_slots
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map(fn {_idx, slot} ->
        input =
          case Jason.decode(IO.iodata_to_binary(slot.args_acc)) do
            {:ok, map} when is_map(map) -> map
            _ -> %{}
          end

        %{
          "type" => "tool_use",
          "id" => slot.id,
          "name" => slot.name,
          "input" => input
        }
      end)

    %{
      "content" => text_block ++ tool_blocks,
      "usage" => %{
        "input_tokens" => s.input_tokens,
        "output_tokens" => s.output_tokens
      },
      "stop_reason" => s.stop_reason
    }
  end

  # --- private event handlers ---

  @spec handle_event(t(), map()) :: {t(), effect()}

  defp handle_event(state, %{"choices" => [choice | _]} = event) do
    state
    |> apply_usage(event)
    |> apply_finish_reason(choice)
    |> apply_delta(choice["delta"] || %{})
  end

  defp handle_event(state, _ignored), do: {state, :none}

  # --- delta dispatch ---

  @spec apply_delta(t(), map()) :: {t(), effect()}

  # text content delta
  defp apply_delta(state, %{"content" => chunk})
       when is_binary(chunk) and chunk != "" do
    {%{state | text: [state.text, chunk]}, {:text, chunk}}
  end

  # tool_calls delta - one or more tool_call increments in one chunk
  defp apply_delta(state, %{"tool_calls" => tc_deltas}) when is_list(tc_deltas) do
    new_slots =
      Enum.reduce(tc_deltas, state.tool_slots, fn delta, slots ->
        idx = delta["index"] || 0
        current = Map.get(slots, idx, %{id: "", name: "", args_acc: []})

        updated = %{
          id: delta["id"] || current.id,
          name: get_in(delta, ["function", "name"]) || current.name,
          args_acc: [current.args_acc, get_in(delta, ["function", "arguments"]) || ""]
        }

        Map.put(slots, idx, updated)
      end)

    {%{state | tool_slots: new_slots}, :none}
  end

  defp apply_delta(state, _delta), do: {state, :none}

  # --- usage and finish reason helpers ---

  @spec apply_usage(t(), map()) :: t()
  defp apply_usage(state, %{"usage" => %{"prompt_tokens" => i, "completion_tokens" => o}}) do
    %{state | input_tokens: state.input_tokens + i, output_tokens: state.output_tokens + o}
  end

  defp apply_usage(state, _), do: state

  @spec apply_finish_reason(t(), map()) :: t()
  defp apply_finish_reason(state, %{"finish_reason" => reason}) when is_binary(reason) do
    %{state | stop_reason: reason}
  end

  defp apply_finish_reason(state, _), do: state
end
