defmodule MiniAgent.Memory do
  @moduledoc """
  Context compression for the agent message history.

  Compression is triggered when token budget consumed exceeds
  :compress_token_threshold (configured in config.exs). The oldest
  messages are summarized via an async Task so the calling GenServer
  is never blocked.
  """

  alias MiniAgent.Budget

  @keep_recent 4
  @summarize_timeout_ms 30_000
  @threshold Application.compile_env!(:mini_agent, :compress_token_threshold)

  @type messages :: list(map())

  @doc """
  Compress messages when token budget exceeds threshold.
  Returns messages unchanged if below threshold or too few to compress.
  """
  @spec maybe_compress(messages(), Budget.t()) :: messages()
  def maybe_compress(messages, %Budget{used: used}) when used < @threshold, do: messages

  def maybe_compress(messages, _budget) when length(messages) <= @keep_recent + 1 do
    messages
  end

  def maybe_compress(messages, _budget) do
    compress(messages)
  end

  @spec compress(messages()) :: messages()
  defp compress(messages) do
    split_at = length(messages) - @keep_recent
    {old, recent} = Enum.split(messages, split_at)

    summary = summarize_async(old)
    before_count = length(messages)
    after_count = length(recent) + 1

    :telemetry.execute(
      [:mini_agent, :memory, :compressed],
      %{before: before_count, after: after_count},
      %{}
    )

    [%{"role" => "user", "content" => "[CONTEXT SUMMARY]\n#{summary}"} | recent]
  end

  @spec summarize_async(messages()) :: String.t()
  defp summarize_async(messages) do
    task =
      Task.Supervisor.async_nolink(MiniAgent.TaskSupervisor, fn ->
        do_summarize(messages)
      end)

    case Task.yield(task, @summarize_timeout_ms) || Task.shutdown(task) do
      {:ok, result} -> result
      {:exit, _reason} -> "(summarization failed, context partially dropped)"
      nil -> "(summarization timed out, context partially dropped)"
    end
  end

  @spec do_summarize(messages()) :: String.t()
  defp do_summarize(messages) do
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

    case llm_module().chat(prompt, system: "You are a context compressor. Be concise.") do
      {:ok, resp} -> llm_module().extract_text(resp)
      {:error, _} -> "(compression failed, context partially dropped)"
    end
  end

  @spec llm_module() :: module()
  defp llm_module, do: Application.fetch_env!(:mini_agent, :llm_module)

  @spec stringify_content(term()) :: String.t()
  defp stringify_content(c) when is_binary(c), do: c
  defp stringify_content(c) when is_list(c), do: c |> inspect() |> String.slice(0, 300)
  defp stringify_content(_), do: ""
end
