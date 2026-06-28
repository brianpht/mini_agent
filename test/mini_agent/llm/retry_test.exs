defmodule MiniAgent.LLM.RetryTest do
  use ExUnit.Case, async: true

  alias MiniAgent.LLM.Retry

  # Atomic call-counter shared across closure invocations.
  defp counter, do: :atomics.new(1, [])
  defp bump(c), do: :atomics.add_get(c, 1, 1)
  defp calls(c), do: :atomics.get(c, 1)

  describe "with_retry/1" do
    test "returns ok without retrying" do
      c = counter()

      assert {:ok, :done} =
               Retry.with_retry(fn ->
                 bump(c)
                 {:ok, :done}
               end)

      assert calls(c) == 1
    end

    test "does not retry a non-retryable error" do
      c = counter()

      assert {:error, :http_error} =
               Retry.with_retry(fn ->
                 bump(c)
                 {:error, :http_error}
               end)

      assert calls(c) == 1
    end

    test "retries a retryable error then succeeds" do
      c = counter()

      fun = fn ->
        if bump(c) < 2, do: {:error, :rate_limited}, else: {:ok, :recovered}
      end

      assert {:ok, :recovered} = Retry.with_retry(fun)
      assert calls(c) == 2
    end
  end

  describe "with_retry_stream/2" do
    test "does not retry once a chunk has reached the caller" do
      c = counter()

      fun = fn on_chunk ->
        bump(c)
        on_chunk.("partial")
        {:error, :rate_limited}
      end

      assert {:error, :rate_limited} = Retry.with_retry_stream(fun, fn _ -> :ok end)
      assert calls(c) == 1
    end

    test "retries when no chunk was emitted, then succeeds" do
      c = counter()

      fun = fn _on_chunk ->
        if bump(c) < 2, do: {:error, :timeout}, else: {:ok, :ok}
      end

      assert {:ok, :ok} = Retry.with_retry_stream(fun, fn _ -> :ok end)
      assert calls(c) == 2
    end
  end
end
