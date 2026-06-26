defmodule MiniAgentWeb.AgentLiveTest do
  @moduledoc false

  use MiniAgentWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "crash detection" do
    @tag :capture_log
    test "transitions to :error when task crashes before broadcasting :done" do
      {:ok, view, _html} = live(build_conn(), "/")

      assert render(view) =~ "idle"

      render_submit(view, :run, %{task: "crash test task"})

      # MockLLM has no expectations set, so the spawned GenServer will crash
      # when it tries to call MockLLM.chat/2. The monitor fires {:DOWN, ...}.
      # Give the task a moment to crash.
      Process.sleep(20)

      html = render(view)
      assert html =~ "error"
    end

    test "transitions to :error on DOWN message with non-normal reason" do
      {:ok, view, _html} = live(build_conn(), "/")

      assert render(view) =~ "idle"

      send(view.pid, {:DOWN, make_ref(), :process, self(), :killed})

      assert render(view) =~ "error"
    end

    test "does not transition on DOWN message with :normal reason" do
      {:ok, view, _html} = live(build_conn(), "/")

      assert render(view) =~ "idle"

      send(view.pid, {:DOWN, make_ref(), :process, self(), :normal})

      assert render(view) =~ "idle"
    end
  end

  describe "normal completion" do
    test "status shows :running after submitting a task" do
      {:ok, view, _html} = live(build_conn(), "/")

      render_submit(view, :run, %{task: "test task"})

      html = render(view)
      assert html =~ "running"
    end

    test "transitions to :done when :done event arrives via handler" do
      {:ok, view, _html} = live(build_conn(), "/")

      assert render(view) =~ "idle"

      send(
        view.pid,
        {:agent_event, %{type: :done, result: "completed", timestamp: DateTime.utc_now()}}
      )

      html = render(view)
      assert html =~ "done"
      assert html =~ "completed"
    end
  end
end
