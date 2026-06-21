defmodule MiniAgentTest do
  use ExUnit.Case

  import Mox

  setup :set_mox_from_context
  setup :verify_on_exit!

  defp done_response do
    %{
      "content" => [%{"type" => "text", "text" => "DONE: task complete"}],
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }
  end

  defp stub_llm_helpers do
    stub(MiniAgent.MockLLM, :extract_text, fn %{"content" => content} ->
      content
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("\n", & &1["text"])
    end)

    stub(MiniAgent.MockLLM, :extract_tool_calls, fn %{"content" => content} ->
      Enum.filter(content, &(&1["type"] == "tool_use"))
    end)

    stub(MiniAgent.MockLLM, :usage, fn %{"usage" => u} ->
      (u["input_tokens"] || 0) + (u["output_tokens"] || 0)
    end)
  end

  describe "run/1 - happy path" do
    test "returns DONE output after single LLM response" do
      stub_llm_helpers()

      expect(MiniAgent.MockLLM, :chat, fn _messages, _opts ->
        {:ok, done_response()}
      end)

      {:ok, pid} = MiniAgent.start_link("explain elixir", mode: :auto)
      output = MiniAgent.run(pid)

      assert output =~ "DONE:"
      assert output =~ "task complete"
    end

    test "increments iterations correctly" do
      stub_llm_helpers()

      # First call returns continue, second returns DONE
      expect(MiniAgent.MockLLM, :chat, fn _messages, _opts ->
        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => "thinking..."}],
           "usage" => %{"input_tokens" => 5, "output_tokens" => 5}
         }}
      end)

      expect(MiniAgent.MockLLM, :chat, fn _messages, _opts ->
        {:ok, done_response()}
      end)

      {:ok, pid} = MiniAgent.start_link("multi-step task", mode: :auto)
      output = MiniAgent.run(pid)

      assert output =~ "DONE:"
    end
  end

  describe "run/1 - error handling" do
    test "returns error output when LLM fails" do
      stub_llm_helpers()

      expect(MiniAgent.MockLLM, :chat, fn _messages, _opts ->
        {:error, "connection refused"}
      end)

      {:ok, pid} = MiniAgent.start_link("some task", mode: :auto)
      output = MiniAgent.run(pid)

      assert output =~ "LLM error"
      assert output =~ "connection refused"
    end
  end

  describe "run/1 - tool calling" do
    test "executes read_file tool and continues" do
      stub_llm_helpers()

      # First response: request a tool call
      expect(MiniAgent.MockLLM, :chat, fn _messages, _opts ->
        {:ok,
         %{
           "content" => [
             %{
               "type" => "tool_use",
               "id" => "tool_1",
               "name" => "read_file",
               "input" => %{"path" => Path.join(System.tmp_dir!(), "nonexistent_test_file.txt")}
             }
           ],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 10}
         }}
      end)

      # Second response: DONE after seeing tool result
      expect(MiniAgent.MockLLM, :chat, fn _messages, _opts ->
        {:ok, done_response()}
      end)

      {:ok, pid} = MiniAgent.start_link("read a file", mode: :auto)
      output = MiniAgent.run(pid)

      assert output =~ "DONE:"
    end
  end
end
