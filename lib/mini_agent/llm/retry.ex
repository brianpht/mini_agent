defmodule MiniAgent.LLM.Retry do
  @moduledoc """
  Exponential-backoff retry wrapper for LLM chat calls.

  Retries transient failures (rate-limit 429, service-unavailable 503,
  network timeouts, connection refused) up to @max_retries times with
  doubling backoff starting at @base_backoff_ms.

  Backoff schedule: 1 s, 2 s, 4 s (7 s total sleep for 3 retries).

  with_retry/1 - wraps chat/2 (non-streaming). Safe to retry unconditionally.

  with_retry_stream/2 - wraps chat_stream/3 (streaming). Retries ONLY when
  zero chunks have been delivered to the caller. Once the first chunk is
  emitted, the attempt is treated as non-retryable to prevent duplicate output.
  """

  @max_retries 3
  @base_backoff_ms 1_000

  @doc """
  Call `fun` and retry on transient LLM errors.

  `fun` must return `{:ok, term()} | {:error, String.t()}`.
  Retries up to #{@max_retries} times with exponential backoff.
  Non-retryable errors (e.g. HTTP 4xx other than 429, 500) are returned
  immediately without retrying.
  """
  @spec with_retry((-> {:ok, term()} | {:error, String.t()})) ::
          {:ok, term()} | {:error, String.t()}
  def with_retry(fun), do: do_retry(fun, 0)

  @doc """
  Wrap a streaming LLM call with connect-only retry.

  `fun` receives a guarded on_chunk callback. The guard sets an atomics flag
  on the first chunk emission. If `fun` returns an error and no chunk was
  emitted yet (flag == 0), the call is retried with the same backoff as
  with_retry/1. Once a chunk reaches the caller, errors are returned
  immediately - no duplicate output.

  `fun` signature: `(on_chunk :: (String.t() -> :ok) -> {:ok, term()} | {:error, String.t()})`
  """
  @spec with_retry_stream(
          ((String.t() -> :ok) -> {:ok, term()} | {:error, String.t()}),
          (String.t() -> :ok)
        ) :: {:ok, term()} | {:error, String.t()}
  def with_retry_stream(fun, on_chunk), do: do_retry_stream(fun, on_chunk, 0)

  # --- private ---

  @spec do_retry((-> {:ok, term()} | {:error, String.t()}), non_neg_integer()) ::
          {:ok, term()} | {:error, String.t()}
  defp do_retry(fun, attempt) do
    case fun.() do
      {:ok, _} = ok ->
        ok

      {:error, reason} = err ->
        if attempt < @max_retries and retryable?(reason) do
          :timer.sleep(backoff_ms(attempt))
          do_retry(fun, attempt + 1)
        else
          err
        end
    end
  end

  @spec do_retry_stream(
          ((String.t() -> :ok) -> {:ok, term()} | {:error, String.t()}),
          (String.t() -> :ok),
          non_neg_integer()
        ) :: {:ok, term()} | {:error, String.t()}
  defp do_retry_stream(fun, on_chunk, attempt) do
    # Fresh atomic per attempt - tracks whether any chunk reached the caller.
    # Index 1, default 0 = no chunk emitted. 1 = at least one chunk emitted.
    received = :atomics.new(1, [])

    guarded = fn chunk ->
      :atomics.put(received, 1, 1)
      on_chunk.(chunk)
    end

    case fun.(guarded) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = err ->
        if attempt < @max_retries and retryable?(reason) and
             :atomics.get(received, 1) == 0 do
          :timer.sleep(backoff_ms(attempt))
          do_retry_stream(fun, on_chunk, attempt + 1)
        else
          err
        end
    end
  end

  # backoff: attempt 0 -> 1000 ms, attempt 1 -> 2000 ms, attempt 2 -> 4000 ms
  @spec backoff_ms(non_neg_integer()) :: non_neg_integer()
  defp backoff_ms(attempt), do: trunc(@base_backoff_ms * :math.pow(2, attempt))

  @spec retryable?(String.t() | term()) :: boolean()
  defp retryable?(reason) when is_binary(reason) do
    String.contains?(reason, ["429", "503", "timeout", "econnrefused", "connection refused"])
  end

  defp retryable?(_), do: false
end
