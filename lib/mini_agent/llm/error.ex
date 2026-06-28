defmodule MiniAgent.LLM.Error do
  @moduledoc false

  @typedoc "Structured LLM error type. Used in place of raw strings for pattern matching."
  @type t ::
          :rate_limited
          | :service_unavailable
          | :timeout
          | :network_error
          | :http_error
          | :unknown

  @doc "True if this error type is transient and worth retrying."
  @spec retryable?(t()) :: boolean()
  def retryable?(:rate_limited), do: true
  def retryable?(:service_unavailable), do: true
  def retryable?(:timeout), do: true
  def retryable?(:network_error), do: true
  def retryable?(:http_error), do: false
  def retryable?(:unknown), do: false

  @doc "Human-readable message for this error type."
  @spec message(t()) :: String.t()
  def message(:rate_limited), do: "Rate limited (HTTP 429)"
  def message(:service_unavailable), do: "Service unavailable (HTTP 503)"
  def message(:timeout), do: "Request timed out"
  def message(:network_error), do: "Network error"
  def message(:http_error), do: "HTTP error"
  def message(:unknown), do: "Unknown error"

  @doc "Classify an HTTP status code into an error type."
  @spec classify_http(integer()) :: t()
  def classify_http(429), do: :rate_limited
  def classify_http(503), do: :service_unavailable
  def classify_http(_), do: :http_error

  @doc """
  Classify a network transport error reason into an error type.

  Expects the error term returned by `Req.post` on network failure
  (e.g. `%Mint.TransportError{reason: :timeout}`, `:econnrefused`, etc.).
  """
  @spec classify_network(term()) :: t()
  def classify_network(%{reason: :timeout}), do: :timeout
  def classify_network(%{reason: :econnrefused}), do: :network_error
  def classify_network(%{reason: :nxdomain}), do: :network_error
  def classify_network(%{reason: :connect_timeout}), do: :timeout
  def classify_network(%{reason: _}), do: :network_error
  def classify_network(:timeout), do: :timeout
  def classify_network(:econnrefused), do: :network_error
  def classify_network(_), do: :network_error
end
