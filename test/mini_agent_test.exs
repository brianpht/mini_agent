defmodule MiniAgentTest do
  use ExUnit.Case
  doctest MiniAgent

  test "greets the world" do
    assert MiniAgent.hello() == :world
  end
end
