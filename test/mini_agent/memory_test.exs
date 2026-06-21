defmodule MiniAgent.MemoryTest do
  use ExUnit.Case, async: true

  alias MiniAgent.{Budget, Memory}

  @threshold Application.compile_env!(:mini_agent, :compress_token_threshold)

  defp under_threshold, do: %Budget{used: @threshold - 1, limit: 50_000}
  defp over_threshold, do: %Budget{used: @threshold + 1, limit: 50_000}

  defp make_messages(n) do
    Enum.map(1..n, fn i ->
      role = if rem(i, 2) == 0, do: "assistant", else: "user"
      %{"role" => role, "content" => "Message #{i}"}
    end)
  end

  describe "maybe_compress/2 - no compression path" do
    test "returns messages unchanged when under token threshold" do
      msgs = make_messages(10)
      assert Memory.maybe_compress(msgs, under_threshold()) == msgs
    end

    test "returns messages unchanged when too few messages even if over threshold" do
      msgs = make_messages(3)
      assert Memory.maybe_compress(msgs, over_threshold()) == msgs
    end

    test "returns messages unchanged at exact keep_recent boundary" do
      # 5 messages = keep_recent(4) + 1 - no compression
      msgs = make_messages(5)
      assert Memory.maybe_compress(msgs, over_threshold()) == msgs
    end
  end

  describe "maybe_compress/2 - compression path" do
    # These tests trigger the LLM mock via @llm_module (MiniAgent.MockLLM in test env).
    # We need the TaskSupervisor running (started by MiniAgent.Application).

    setup do
      Mox.stub(MiniAgent.MockLLM, :chat, fn _msgs, _opts ->
        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => "- did some work"}],
           "usage" => %{"input_tokens" => 5, "output_tokens" => 5}
         }}
      end)

      Mox.stub(MiniAgent.MockLLM, :extract_text, fn %{"content" => content} ->
        content
        |> Enum.filter(&(&1["type"] == "text"))
        |> Enum.map_join("\n", & &1["text"])
      end)

      :ok
    end

    test "returns fewer messages after compression" do
      msgs = make_messages(10)
      result = Memory.maybe_compress(msgs, over_threshold())
      assert length(result) < length(msgs)
    end

    test "never returns empty list" do
      msgs = make_messages(10)
      result = Memory.maybe_compress(msgs, over_threshold())
      assert result != []
    end

    test "result starts with a summary message" do
      msgs = make_messages(10)
      [first | _] = Memory.maybe_compress(msgs, over_threshold())
      assert first["role"] == "user"
      assert String.starts_with?(first["content"], "[CONTEXT SUMMARY]")
    end
  end
end
