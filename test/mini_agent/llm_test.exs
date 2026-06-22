defmodule MiniAgent.LLMTest do
  use ExUnit.Case, async: true

  alias MiniAgent.LLM.Anthropic, as: LLM

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
      %{"type" => "tool_use", "id" => "t1", "name" => "read_file", "input" => %{"path" => "x"}}
    ],
    "usage" => %{"input_tokens" => 20, "output_tokens" => 8}
  }

  describe "extract_text/1" do
    test "joins text blocks with newline" do
      assert LLM.extract_text(@text_response) == "Hello\nWorld"
    end

    test "ignores non-text blocks" do
      assert LLM.extract_text(@tool_response) == "Calling tool"
    end

    test "returns empty string for unknown format" do
      assert LLM.extract_text(%{}) == ""
    end
  end

  describe "extract_tool_calls/1" do
    test "returns empty list when no tool calls" do
      assert LLM.extract_tool_calls(@text_response) == []
    end

    test "returns tool_use blocks" do
      calls = LLM.extract_tool_calls(@tool_response)
      assert length(calls) == 1
      assert hd(calls)["name"] == "read_file"
    end

    test "returns empty list for unknown format" do
      assert LLM.extract_tool_calls(%{}) == []
    end
  end

  describe "usage/1" do
    test "sums input and output tokens" do
      assert LLM.usage(@text_response) == 15
    end

    test "returns 0 for unknown format" do
      assert LLM.usage(%{}) == 0
    end
  end
end
