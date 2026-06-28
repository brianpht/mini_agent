defmodule MiniAgent.LLM.DeepSeekStreamParserTest do
  use ExUnit.Case, async: true

  alias MiniAgent.LLM.DeepSeekStreamParser, as: Parser

  defp line(event), do: "data: " <> Jason.encode!(event)

  defp run(lines) do
    Enum.reduce(lines, Parser.new(), fn l, p ->
      {p2, _effect} = Parser.handle_line(p, l)
      p2
    end)
  end

  describe "text streaming" do
    test "accumulates content deltas into a single text block" do
      resp =
        [
          line(%{"choices" => [%{"delta" => %{"content" => "Hello"}}]}),
          line(%{"choices" => [%{"delta" => %{"content" => " world"}}]})
        ]
        |> run()
        |> Parser.to_response()

      assert resp["content"] == [%{"type" => "text", "text" => "Hello world"}]
    end

    test "a content delta yields a {:text, chunk} effect" do
      assert {_state, {:text, "hi"}} =
               Parser.handle_line(
                 Parser.new(),
                 line(%{"choices" => [%{"delta" => %{"content" => "hi"}}]})
               )
    end
  end

  describe "tool_call assembly" do
    test "assembles a tool_use block from incremental tool_call deltas" do
      resp =
        [
          line(%{
            "choices" => [
              %{
                "delta" => %{
                  "tool_calls" => [
                    %{
                      "index" => 0,
                      "id" => "call_1",
                      "function" => %{"name" => "read_file", "arguments" => ""}
                    }
                  ]
                }
              }
            ]
          }),
          line(%{
            "choices" => [
              %{
                "delta" => %{
                  "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "{\"path\":"}}]
                }
              }
            ]
          }),
          line(%{
            "choices" => [
              %{
                "delta" => %{
                  "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => " \"a.txt\"}"}}]
                }
              }
            ]
          })
        ]
        |> run()
        |> Parser.to_response()

      assert resp["content"] == [
               %{
                 "type" => "tool_use",
                 "id" => "call_1",
                 "name" => "read_file",
                 "input" => %{"path" => "a.txt"}
               }
             ]
    end
  end

  describe "usage and robustness" do
    test "records token usage and stop_reason from the finish chunk" do
      resp =
        [
          line(%{
            "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}],
            "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}
          })
        ]
        |> run()
        |> Parser.to_response()

      assert resp["stop_reason"] == "stop"
      assert resp["usage"] == %{"input_tokens" => 10, "output_tokens" => 5}
    end

    test "handles the [DONE] terminator gracefully" do
      assert {_state, :none} = Parser.handle_line(Parser.new(), "data: [DONE]")
    end

    test "ignores malformed json without changing state" do
      {state, effect} = Parser.handle_line(Parser.new(), "data: {not json")
      assert effect == :none
      assert state == Parser.new()
    end
  end
end
