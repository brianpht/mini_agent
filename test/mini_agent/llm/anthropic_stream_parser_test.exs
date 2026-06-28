defmodule MiniAgent.LLM.AnthropicStreamParserTest do
  use ExUnit.Case, async: true

  alias MiniAgent.LLM.AnthropicStreamParser, as: Parser

  defp line(event), do: "data: " <> Jason.encode!(event)

  defp run(lines) do
    Enum.reduce(lines, Parser.new(), fn l, p ->
      {p2, _effect} = Parser.handle_line(p, l)
      p2
    end)
  end

  describe "text streaming" do
    test "accumulates text deltas into a single text block" do
      resp =
        [
          line(%{"type" => "content_block_start", "content_block" => %{"type" => "text"}}),
          line(%{
            "type" => "content_block_delta",
            "delta" => %{"type" => "text_delta", "text" => "Hello"}
          }),
          line(%{
            "type" => "content_block_delta",
            "delta" => %{"type" => "text_delta", "text" => " world"}
          })
        ]
        |> run()
        |> Parser.to_response()

      assert resp["content"] == [%{"type" => "text", "text" => "Hello world"}]
    end

    test "a text delta yields a {:text, chunk} effect for live output" do
      assert {_state, {:text, "hi"}} =
               Parser.handle_line(
                 Parser.new(),
                 line(%{
                   "type" => "content_block_delta",
                   "delta" => %{"type" => "text_delta", "text" => "hi"}
                 })
               )
    end
  end

  describe "tool_use assembly" do
    test "assembles a tool_use block from streamed partial json" do
      resp =
        [
          line(%{
            "type" => "content_block_start",
            "content_block" => %{"type" => "tool_use", "id" => "toolu_1", "name" => "read_file"}
          }),
          line(%{
            "type" => "content_block_delta",
            "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"path\":"}
          }),
          line(%{
            "type" => "content_block_delta",
            "delta" => %{"type" => "input_json_delta", "partial_json" => " \"a.txt\"}"}
          }),
          line(%{"type" => "content_block_stop"})
        ]
        |> run()
        |> Parser.to_response()

      assert resp["content"] == [
               %{
                 "type" => "tool_use",
                 "id" => "toolu_1",
                 "name" => "read_file",
                 "input" => %{"path" => "a.txt"}
               }
             ]
    end
  end

  describe "usage and robustness" do
    test "totals token usage from message_start and message_delta" do
      resp =
        [
          line(%{"type" => "message_start", "message" => %{"usage" => %{"input_tokens" => 10}}}),
          line(%{
            "type" => "message_delta",
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => %{"output_tokens" => 5}
          })
        ]
        |> run()

      out = Parser.to_response(resp)
      assert out["stop_reason"] == "end_turn"
      # Anthropic parser accumulates both counts into output_tokens.
      assert out["usage"]["output_tokens"] == 15
    end

    test "ignores malformed json lines without changing state" do
      {state, effect} = Parser.handle_line(Parser.new(), "data: {not json")
      assert effect == :none
      assert state == Parser.new()
    end

    test "ignores non-data lines" do
      assert {_state, :none} = Parser.handle_line(Parser.new(), "event: ping")
    end
  end
end
