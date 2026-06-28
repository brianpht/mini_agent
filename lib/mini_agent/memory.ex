defmodule MiniAgent.Memory do
  @keep_recent 4
  @summarize_timeout_ms 30_000
  @threshold Application.compile_env!(:mini_agent, :compress_token_threshold)

  @moduledoc """
  Context compression for the agent message history.

  Compression is triggered when token budget consumed exceeds
  :compress_token_threshold (configured in config.exs). The oldest
  messages are summarized via a Task to isolate crashes - the caller
  yields for up to #{@summarize_timeout_ms}ms waiting for the result.
  The call IS blocking; the benefit is crash isolation, not concurrency.

  ## Boundary safety

  The split point is adjusted backwards if it would orphan a
  tool_result message from its paired tool_use. This prevents sending
  a conversation history that violates the Anthropic API contract.
  If no safe split is possible (all old messages are tool turns), the
  compression round is skipped and messages are returned unchanged.
  """

  alias MiniAgent.{Budget, LLM.Retry}

  @type messages :: list(map())

  @doc """
  Compress messages when token budget exceeds threshold.
  Returns messages unchanged if below threshold or too few to compress.
  """
  @spec maybe_compress(messages(), Budget.t(), module()) :: messages()
  def maybe_compress(messages, %Budget{used: used}, _llm_mod) when used < @threshold, do: messages

  def maybe_compress(messages, _budget, _llm_mod) when length(messages) <= @keep_recent + 1 do
    messages
  end

  def maybe_compress(messages, _budget, llm_mod) do
    compress(messages, llm_mod)
  end

  @spec compress(messages(), module()) :: messages()
  defp compress(messages, llm_mod) do
    initial_split = length(messages) - @keep_recent
    split_at = safe_split_at(messages, initial_split)

    if split_at < 2 do
      # Not enough old messages for a safe split this round; skip compression.
      messages
    else
      {old, recent} = Enum.split(messages, split_at)

      summary = summarize_async(old, llm_mod)
      before_count = length(messages)
      after_count = length(recent) + 1

      :telemetry.execute(
        [:mini_agent, :memory, :compressed],
        %{before: before_count, after: after_count},
        %{}
      )

      [%{"role" => "user", "content" => "[CONTEXT SUMMARY]\n#{summary}"} | recent]
    end
  end

  # Walk the split index backwards until the first message of `recent` is NOT
  # an orphaned tool_result block. This preserves tool_use / tool_result pairs.
  @spec safe_split_at(messages(), non_neg_integer()) :: non_neg_integer()
  defp safe_split_at(_messages, split_at) when split_at <= 1, do: split_at

  defp safe_split_at(messages, split_at) do
    msg = Enum.at(messages, split_at)

    if orphaned_tool_result?(msg) do
      safe_split_at(messages, split_at - 1)
    else
      split_at
    end
  end

  # A user message whose content list starts with a tool_result block is an
  # orphan if it appears at the beginning of `recent` without its preceding
  # assistant tool_use message.
  @spec orphaned_tool_result?(map() | nil) :: boolean()
  defp orphaned_tool_result?(%{"content" => [%{"type" => "tool_result"} | _]}), do: true
  defp orphaned_tool_result?(_), do: false

  @spec summarize_async(messages(), module()) :: String.t()
  defp summarize_async(messages, llm_mod) do
    task =
      Task.Supervisor.async_nolink(MiniAgent.TaskSupervisor, fn ->
        do_summarize(messages, llm_mod)
      end)

    case Task.yield(task, @summarize_timeout_ms) || Task.shutdown(task) do
      {:ok, result} -> result
      {:exit, _reason} -> "(summarization failed, context partially dropped)"
      nil -> "(summarization timed out, context partially dropped)"
    end
  end

  @spec do_summarize(messages(), module()) :: String.t()
  defp do_summarize(messages, llm_mod) do
    transcript =
      Enum.map_join(messages, "\n", fn m ->
        role = m["role"] || m[:role] || "unknown"
        content = stringify_content(m["content"] || m[:content])
        "#{role}: #{String.slice(content, 0, 300)}"
      end)

    prompt = [
      %{
        "role" => "user",
        "content" =>
          "Summarize the following conversation in 3-5 bullet points. " <>
            "Keep: goal, files read/modified, key decisions.\n\n#{transcript}"
      }
    ]

    result =
      Retry.with_retry(fn ->
        llm_mod.chat(prompt, system: "You are a context compressor. Be concise.")
      end)

    case result do
      {:ok, resp} -> llm_mod.extract_text(resp)
      {:error, _} -> "(compression failed, context partially dropped)"
    end
  end

  @spec stringify_content(term()) :: String.t()
  defp stringify_content(c) when is_binary(c), do: c
  defp stringify_content(c) when is_list(c), do: c |> inspect() |> String.slice(0, 300)
  defp stringify_content(_), do: ""
end
