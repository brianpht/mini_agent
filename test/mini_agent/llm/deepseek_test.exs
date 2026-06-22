defmodule MiniAgent.LLM.DeepSeekTest do
  use ExUnit.Case, async: true

  alias MiniAgent.LLM.DeepSeek

  # Simulates a normalized response produced by normalize_response/1 inside DeepSeek.chat/2.
  # These are tested via the public extract_* and usage/1 callbacks.

  @text_response %{
    "content" => [
      %{"type" => "text", "text" => "Hello"},
      %{"type" => "text", "text" => "World"}
    ],
    "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
  }

  @tool_response %{
    "content" => [
      %{"type" => "text", "text" => "Calling tool"},
      %{
        "type" => "tool_use",
        "id" => "call_1",
        "name" => "read_file",
        "input" => %{"path" => "x.ex"}
      }
    ],
    "usage" => %{"input_tokens" => 20, "output_tokens" => 8}
  }

  describe "extract_text/1" do
    test "joins text blocks with newline" do
      assert DeepSeek.extract_text(@text_response) == "Hello\nWorld"
    end

    test "ignores tool_use blocks" do
      assert DeepSeek.extract_text(@tool_response) == "Calling tool"
    end

    test "returns empty string for unknown format" do
      assert DeepSeek.extract_text(%{}) == ""
    end
  end

  describe "extract_tool_calls/1" do
    test "returns empty list when no tool calls" do
      assert DeepSeek.extract_tool_calls(@text_response) == []
    end

    test "returns tool_use blocks with name and input" do
      calls = DeepSeek.extract_tool_calls(@tool_response)
      assert length(calls) == 1
      call = hd(calls)
      assert call["name"] == "read_file"
      assert call["input"] == %{"path" => "x.ex"}
      assert call["id"] == "call_1"
    end

    test "returns empty list for unknown format" do
      assert DeepSeek.extract_tool_calls(%{}) == []
    end
  end

  describe "usage/1" do
    test "sums input and output tokens" do
      assert DeepSeek.usage(@text_response) == 15
    end

    test "returns 0 for missing usage" do
      assert DeepSeek.usage(%{}) == 0
    end
  end
end
