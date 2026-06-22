defmodule MiniAgent.LLM.StreamParserTest do
  use ExUnit.Case, async: true

  alias MiniAgent.LLM.StreamParser

  describe "new/0" do
    test "returns empty struct" do
      parser = StreamParser.new()
      assert parser.text == ""
      assert parser.tool_calls == []
      assert parser.current_tool == nil
      assert parser.usage == 0
      assert parser.stop_reason == nil
    end
  end

  describe "handle_line/2 - text delta" do
    test "accumulates text and returns {:text, chunk} effect" do
      parser = StreamParser.new()
      line = ~s(data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}})

      {new_parser, effect} = StreamParser.handle_line(parser, line)

      assert new_parser.text == "Hello"
      assert effect == {:text, "Hello"}
    end

    test "concatenates multiple text deltas" do
      parser = StreamParser.new()

      line1 =
        ~s(data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}})

      line2 =
        ~s(data: {"type":"content_block_delta","delta":{"type":"text_delta","text":" World"}})

      {p1, _} = StreamParser.handle_line(parser, line1)
      {p2, _} = StreamParser.handle_line(p1, line2)

      assert p2.text == "Hello World"
    end
  end

  describe "handle_line/2 - non-SSE lines" do
    test "ignores blank lines" do
      parser = StreamParser.new()
      {new_parser, effect} = StreamParser.handle_line(parser, "")
      assert new_parser == parser
      assert effect == :none
    end

    test "ignores comment lines" do
      parser = StreamParser.new()
      {new_parser, effect} = StreamParser.handle_line(parser, ": keep-alive")
      assert new_parser == parser
      assert effect == :none
    end

    test "ignores invalid JSON in data line" do
      parser = StreamParser.new()
      {new_parser, effect} = StreamParser.handle_line(parser, "data: not json")
      assert new_parser == parser
      assert effect == :none
    end
  end

  describe "handle_line/2 - tool use lifecycle" do
    test "tracks tool_use start, input deltas, and stop" do
      parser = StreamParser.new()

      # content_block_start with tool_use
      start_line =
        "data: " <>
          Jason.encode!(%{
            "type" => "content_block_start",
            "content_block" => %{"type" => "tool_use", "id" => "tid1", "name" => "read_file"}
          })

      {p1, e1} = StreamParser.handle_line(parser, start_line)
      assert e1 == :none
      assert p1.current_tool["id"] == "tid1"
      assert p1.current_tool["name"] == "read_file"
      assert p1.current_json == ""

      # input_json_delta - first chunk (partial JSON, not yet valid)
      delta1 =
        "data: " <>
          Jason.encode!(%{
            "type" => "content_block_delta",
            "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"path":)}
          })

      {p2, e2} = StreamParser.handle_line(p1, delta1)
      assert e2 == :none
      assert p2.current_json == ~s({"path":)

      # input_json_delta - second chunk (completes the JSON)
      delta2 =
        "data: " <>
          Jason.encode!(%{
            "type" => "content_block_delta",
            "delta" => %{"type" => "input_json_delta", "partial_json" => ~s("test.ex"})}
          })

      {p3, e3} = StreamParser.handle_line(p2, delta2)
      assert e3 == :none
      assert p3.current_json == ~s({"path":"test.ex"})

      # content_block_stop - finalize tool
      stop_line = "data: " <> Jason.encode!(%{"type" => "content_block_stop"})
      {p4, e4} = StreamParser.handle_line(p3, stop_line)
      assert e4 == :none
      assert p4.current_tool == nil
      assert p4.current_json == ""
      assert length(p4.tool_calls) == 1
      assert hd(p4.tool_calls)["name"] == "read_file"
      assert hd(p4.tool_calls)["input"] == %{"path" => "test.ex"}
    end

    test "content_block_stop without current_tool is a no-op" do
      parser = StreamParser.new()
      stop_line = "data: " <> Jason.encode!(%{"type" => "content_block_stop"})
      {new_parser, effect} = StreamParser.handle_line(parser, stop_line)
      assert new_parser == parser
      assert effect == :none
    end
  end

  describe "handle_line/2 - token counting" do
    test "accumulates input tokens from message_start" do
      parser = StreamParser.new()

      line =
        ~s(data: {"type":"message_start","message":{"usage":{"input_tokens":42,"output_tokens":0}}})

      {new_parser, effect} = StreamParser.handle_line(parser, line)
      assert new_parser.usage == 42
      assert effect == :none
    end

    test "accumulates output tokens from message_delta" do
      parser = StreamParser.new()

      line =
        ~s(data: {"type":"message_delta","usage":{"output_tokens":17},"delta":{"stop_reason":"end_turn"}})

      {new_parser, effect} = StreamParser.handle_line(parser, line)
      assert new_parser.usage == 17
      assert new_parser.stop_reason == "end_turn"
      assert effect == :none
    end
  end

  describe "to_response/1" do
    test "produces Anthropic-compatible response map for text-only response" do
      parser = %StreamParser{
        text: "Hello World",
        tool_calls: [],
        usage: 30,
        stop_reason: "end_turn"
      }

      resp = StreamParser.to_response(parser)

      assert resp["stop_reason"] == "end_turn"
      assert resp["usage"]["output_tokens"] == 30
      assert length(resp["content"]) == 1
      assert hd(resp["content"])["type"] == "text"
      assert hd(resp["content"])["text"] == "Hello World"
    end

    test "includes tool_use blocks in content" do
      parser = %StreamParser{
        text: "Using tool",
        tool_calls: [%{"id" => "t1", "name" => "read_file", "input" => %{"path" => "x"}}],
        usage: 10,
        stop_reason: "tool_use"
      }

      resp = StreamParser.to_response(parser)

      assert length(resp["content"]) == 2
      text_block = Enum.find(resp["content"], &(&1["type"] == "text"))
      tool_block = Enum.find(resp["content"], &(&1["type"] == "tool_use"))
      assert text_block["text"] == "Using tool"
      assert tool_block["name"] == "read_file"
      assert tool_block["input"] == %{"path" => "x"}
    end

    test "omits text block when text is empty" do
      parser = %StreamParser{
        text: "",
        tool_calls: [%{"id" => "t1", "name" => "shell", "input" => %{"command" => "ls"}}],
        usage: 5,
        stop_reason: "tool_use"
      }

      resp = StreamParser.to_response(parser)

      assert length(resp["content"]) == 1
      assert hd(resp["content"])["type"] == "tool_use"
    end

    test "round-trip: response is compatible with LLM.Anthropic extract functions" do
      alias MiniAgent.LLM.Anthropic

      parser = %StreamParser{
        text: "Result text",
        tool_calls: [%{"id" => "t2", "name" => "list_dir", "input" => %{"path" => "."}}],
        usage: 20,
        stop_reason: "tool_use"
      }

      resp = StreamParser.to_response(parser)

      assert Anthropic.extract_text(resp) == "Result text"
      calls = Anthropic.extract_tool_calls(resp)
      assert length(calls) == 1
      assert hd(calls)["name"] == "list_dir"
      assert Anthropic.usage(resp) == 20
    end
  end
end
