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

    test "does not orphan a tool_result at the split boundary" do
      # Build: [user, asst+tool_use, user+tool_result, asst, user, asst, user, asst, user, asst]
      # That is 10 messages. Default split_at = 10 - 4 = 6.
      # Message at index 6 is a user+tool_result - must be walked back.
      tool_use_msg = %{
        "role" => "assistant",
        "content" => [
          %{"type" => "tool_use", "id" => "t1", "name" => "read_file", "input" => %{}}
        ]
      }

      tool_result_msg = %{
        "role" => "user",
        "content" => [%{"type" => "tool_result", "tool_use_id" => "t1", "content" => "data"}]
      }

      plain = fn i -> %{"role" => "user", "content" => "msg #{i}"} end

      msgs = [
        plain.(1),
        plain.(2),
        plain.(3),
        plain.(4),
        tool_use_msg,
        tool_result_msg,
        plain.(7),
        plain.(8),
        plain.(9),
        plain.(10)
      ]

      result = Memory.maybe_compress(msgs, over_threshold())

      # The first message of recent must NOT be a tool_result
      [_summary | recent] = result

      refute match?(
               %{"content" => [%{"type" => "tool_result"} | _]},
               hd(recent)
             )
    end

    test "skips compression when all old messages are tool turns (safe split < 2)" do
      # 6 messages: [user, asst+tool_use, user+tool_result, asst+tool_use, user+tool_result, asst]
      # split_at = 6 - 4 = 2. msg[2] = user+tool_result -> walk back to 1 -> still < 2 -> skip
      tool_pair = fn id ->
        [
          %{
            "role" => "assistant",
            "content" => [
              %{"type" => "tool_use", "id" => id, "name" => "read_file", "input" => %{}}
            ]
          },
          %{
            "role" => "user",
            "content" => [%{"type" => "tool_result", "tool_use_id" => id, "content" => "x"}]
          }
        ]
      end

      msgs =
        [%{"role" => "user", "content" => "task"}] ++
          tool_pair.("a") ++
          tool_pair.("b") ++
          [%{"role" => "assistant", "content" => "thinking"}]

      result = Memory.maybe_compress(msgs, over_threshold())
      # Compression skipped - messages returned unchanged
      assert result == msgs
    end
  end
end
