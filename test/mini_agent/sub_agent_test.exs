defmodule MiniAgent.SubAgentTest do
  use ExUnit.Case, async: true

  import Mox

  setup :verify_on_exit!

  describe "run/2" do
    test "returns DONE output when LLM replies with DONE:" do
      MiniAgent.MockLLM
      |> expect(:chat, fn _messages, _opts ->
        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => "DONE: found 3 files"}],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 5},
           "stop_reason" => "end_turn"
         }}
      end)
      |> stub(:extract_text, fn resp ->
        resp["content"]
        |> Enum.filter(&(&1["type"] == "text"))
        |> Enum.map_join("\n", & &1["text"])
      end)
      |> stub(:extract_tool_calls, fn resp ->
        Enum.filter(resp["content"], &(&1["type"] == "tool_use"))
      end)
      |> stub(:usage, fn resp ->
        (get_in(resp, ["usage", "input_tokens"]) || 0) +
          (get_in(resp, ["usage", "output_tokens"]) || 0)
      end)

      assert {:ok, output, tokens} = MiniAgent.SubAgent.run("list files in lib/", mode: :readonly)
      assert String.starts_with?(output, "DONE:")
      assert is_integer(tokens) and tokens >= 0
    end

    test "terminates after max iterations without DONE:" do
      # Always returns a non-DONE response, no tool calls
      MiniAgent.MockLLM
      |> stub(:chat, fn _messages, _opts ->
        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => "still thinking..."}],
           "usage" => %{"input_tokens" => 5, "output_tokens" => 3},
           "stop_reason" => "end_turn"
         }}
      end)
      |> stub(:extract_text, fn resp ->
        resp["content"]
        |> Enum.filter(&(&1["type"] == "text"))
        |> Enum.map_join("\n", & &1["text"])
      end)
      |> stub(:extract_tool_calls, fn _resp -> [] end)
      |> stub(:usage, fn _resp -> 8 end)

      assert {:ok, output, tokens} =
               MiniAgent.SubAgent.run("do something", mode: :readonly, id: "test")

      # last output is the non-DONE text
      assert output == "still thinking..."
      assert is_integer(tokens) and tokens >= 0
    end

    test "returns error when LLM returns error" do
      MiniAgent.MockLLM
      |> expect(:chat, fn _messages, _opts ->
        {:error, "HTTP 500: internal server error"}
      end)
      |> stub(:extract_text, fn _ -> "" end)
      |> stub(:extract_tool_calls, fn _ -> [] end)
      |> stub(:usage, fn _ -> 0 end)

      assert {:ok, output, tokens} = MiniAgent.SubAgent.run("failing task", mode: :readonly)
      assert String.contains?(output, "LLM error")
      assert is_integer(tokens) and tokens >= 0
    end

    test "executes tool calls and appends results to messages" do
      # First call: return tool_use; second call: return DONE:
      MiniAgent.MockLLM
      |> expect(:chat, fn messages, _opts ->
        # first call - should only have original user message
        assert length(messages) == 1

        {:ok,
         %{
           "content" => [
             %{
               "type" => "tool_use",
               "id" => "tool_1",
               "name" => "list_dir",
               "input" => %{"path" => "."}
             }
           ],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 8},
           "stop_reason" => "tool_use"
         }}
      end)
      |> expect(:chat, fn messages, _opts ->
        # second call - should include assistant msg + tool result
        assert length(messages) == 3

        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => "DONE: listed directory"}],
           "usage" => %{"input_tokens" => 15, "output_tokens" => 6},
           "stop_reason" => "end_turn"
         }}
      end)
      |> stub(:extract_text, fn resp ->
        resp["content"]
        |> Enum.filter(&(&1["type"] == "text"))
        |> Enum.map_join("\n", & &1["text"])
      end)
      |> stub(:extract_tool_calls, fn resp ->
        Enum.filter(resp["content"], &(&1["type"] == "tool_use"))
      end)
      |> stub(:usage, fn resp ->
        (get_in(resp, ["usage", "input_tokens"]) || 0) +
          (get_in(resp, ["usage", "output_tokens"]) || 0)
      end)

      assert {:ok, output, tokens} =
               MiniAgent.SubAgent.run("explore project", mode: :readonly, id: 1)

      assert String.starts_with?(output, "DONE:")
      assert is_integer(tokens) and tokens > 0
    end
  end
end
