defmodule MiniAgent.BudgetTest do
  use ExUnit.Case, async: true

  alias MiniAgent.Budget

  describe "new/0" do
    test "creates budget with compiled limit" do
      budget = Budget.new()
      assert budget.used == 0
      assert budget.limit > 0
    end
  end

  describe "add/2" do
    test "increases used tokens" do
      budget = Budget.new()
      assert Budget.add(budget, 100).used == 100
    end

    test "is monotonically increasing" do
      budget = Budget.new()
      b1 = Budget.add(budget, 100)
      b2 = Budget.add(b1, 200)
      assert b2.used > b1.used
      assert b2.used == 300
    end

    test "does not change the limit" do
      budget = Budget.new()
      assert Budget.add(budget, 999).limit == budget.limit
    end
  end

  describe "exceeded?/1" do
    test "false when under limit" do
      refute Budget.exceeded?(%Budget{used: 0, limit: 1_000})
    end

    test "true when at limit" do
      assert Budget.exceeded?(%Budget{used: 1_000, limit: 1_000})
    end

    test "true when over limit" do
      assert Budget.exceeded?(%Budget{used: 1_500, limit: 1_000})
    end
  end

  describe "remaining/1" do
    test "returns difference when under limit" do
      assert Budget.remaining(%Budget{used: 200, limit: 1_000}) == 800
    end

    test "returns 0 when exceeded" do
      assert Budget.remaining(%Budget{used: 1_500, limit: 1_000}) == 0
    end
  end

  describe "report/1" do
    test "returns string containing usage numbers" do
      report = Budget.report(%Budget{used: 500, limit: 1_000})
      assert is_binary(report)
      assert report =~ "500"
      assert report =~ "1000"
    end
  end
end
