defmodule MiniAgent.Budget do
  @moduledoc "Tracks and enforces token consumption quota. Pure struct - no process."

  @enforce_keys [:limit]
  defstruct used: 0, limit: 50_000

  @type t :: %__MODULE__{
          used: non_neg_integer(),
          limit: pos_integer()
        }

  @limit Application.compile_env!(:mini_agent, :token_budget)

  @doc "Create a new budget from compiled config."
  @spec new() :: t()
  def new, do: %__MODULE__{limit: @limit}

  @doc "Add consumed tokens. Returns updated budget."
  @spec add(t(), non_neg_integer()) :: t()
  def add(%__MODULE__{} = b, tokens) when is_integer(tokens) and tokens >= 0 do
    %{b | used: b.used + tokens}
  end

  @doc "True when used tokens >= limit."
  @spec exceeded?(t()) :: boolean()
  def exceeded?(%__MODULE__{used: used, limit: limit}), do: used >= limit

  @doc "Remaining tokens before limit is hit (minimum 0)."
  @spec remaining(t()) :: non_neg_integer()
  def remaining(%__MODULE__{used: used, limit: limit}), do: max(0, limit - used)

  @doc "Human-readable usage report string."
  @spec report(t()) :: String.t()
  def report(%__MODULE__{used: used, limit: limit}) do
    pct = Float.round(used / limit * 100, 1)
    "Token: #{used}/#{limit} (#{pct}%)"
  end
end
