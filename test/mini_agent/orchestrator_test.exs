defmodule MiniAgent.OrchestratorTest do
  use ExUnit.Case, async: true

  import Mox

  setup :verify_on_exit!

  # Shared stub helpers - all tests need these for sub-agent calls
  defp stub_llm_helpers do
    MiniAgent.MockLLM
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
  end

  defp done_response(text) do
    %{
      "content" => [%{"type" => "text", "text" => text}],
      "usage" => %{"input_tokens" => 5, "output_tokens" => 5},
      "stop_reason" => "end_turn"
    }
  end

  describe "run/2 - plan phase" do
    test "splits task into subtasks and runs them" do
      stub_llm_helpers()

      # plan call returns 2 subtasks
      plan_response = done_response("Check lib/ structure\nCheck test/ structure")

      # 2 sub-agent calls, each returning DONE:
      sub_response_1 = done_response("DONE: lib has 10 files")
      sub_response_2 = done_response("DONE: test has 5 files")

      # synthesis call
      synth_response = done_response("The project has 10 lib files and 5 test files.")

      MiniAgent.MockLLM
      |> expect(:chat, fn _messages, [system: system] ->
        assert String.contains?(system, "planner")
        {:ok, plan_response}
      end)
      |> expect(:chat, 2, fn _messages, _opts ->
        # sub-agent calls - return alternating responses
        Process.put(:call_count, (Process.get(:call_count) || 0) + 1)

        if rem(Process.get(:call_count), 2) == 1,
          do: {:ok, sub_response_1},
          else: {:ok, sub_response_2}
      end)
      |> expect(:chat, fn _messages, [system: system] ->
        assert String.contains?(system, "synthesiz")
        {:ok, synth_response}
      end)

      result = MiniAgent.Orchestrator.run("Analyze project structure", mode: :readonly)
      assert is_binary(result)
      assert String.length(result) > 0
    end
  end

  describe "run/2 - fallback when plan fails" do
    test "falls back to single-task when LLM plan call errors" do
      stub_llm_helpers()

      MiniAgent.MockLLM
      # plan call fails
      |> expect(:chat, fn _messages, [system: system] ->
        assert String.contains?(system, "planner")
        {:error, "HTTP 500"}
      end)
      # single sub-agent call (fallback to original task)
      |> expect(:chat, fn _messages, _opts ->
        {:ok, done_response("DONE: analyzed")}
      end)
      # synthesis call
      |> expect(:chat, fn _messages, _opts ->
        {:ok, done_response("Final synthesis result")}
      end)

      result = MiniAgent.Orchestrator.run("Do something", mode: :readonly)
      assert is_binary(result)
    end
  end

  describe "run/2 - synthesis fallback" do
    test "returns raw results when synthesis LLM call fails" do
      stub_llm_helpers()

      plan_response = done_response("Task A\nTask B")

      MiniAgent.MockLLM
      |> expect(:chat, fn _messages, [system: system] ->
        assert String.contains?(system, "planner")
        {:ok, plan_response}
      end)
      |> expect(:chat, 2, fn _messages, _opts ->
        {:ok, done_response("DONE: subtask done")}
      end)
      # synthesis fails with a non-retryable error
      |> expect(:chat, fn _messages, _opts ->
        {:error, "HTTP 400: bad synthesis request"}
      end)

      result = MiniAgent.Orchestrator.run("Complex task", mode: :readonly)
      # fallback includes raw results string
      assert String.contains?(result, "Synthesis failed")
    end
  end
end
