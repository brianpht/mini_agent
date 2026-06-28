defmodule MiniAgent.CheckpointTest do
  # async: false - mutates the :checkpoint_dir application env.
  use ExUnit.Case, async: false

  alias MiniAgent.{Budget, Checkpoint}

  setup do
    dir = Path.join(System.tmp_dir!(), "checkpoint_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prev = Application.get_env(:mini_agent, :checkpoint_dir)
    Application.put_env(:mini_agent, :checkpoint_dir, dir)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:mini_agent, :checkpoint_dir, prev),
        else: Application.delete_env(:mini_agent, :checkpoint_dir)

      File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  defp sample_state do
    %MiniAgent.State{
      session_id: "test-session-#{System.unique_integer([:positive])}",
      task: "do a thing",
      mode: :auto,
      workspace: System.tmp_dir!(),
      iterations: 3,
      done: false,
      output: nil,
      budget: %Budget{used: 1234, limit: 50_000},
      messages: [
        %{"role" => "user", "content" => "hello"},
        %{"role" => "assistant", "content" => "hi"}
      ]
    }
  end

  defp write_raw(dir, session_id, map) do
    File.write!(Path.join(dir, "#{session_id}.json"), Jason.encode!(map))
  end

  describe "save/1 and load/1 round-trip" do
    test "restores task, mode, iterations, budget and messages" do
      state = sample_state()
      sid = Checkpoint.save(state)

      assert {:ok, loaded} = Checkpoint.load(sid)
      assert loaded.task == state.task
      assert loaded.mode == :auto
      assert loaded.iterations == 3
      assert loaded.budget.used == 1234
      assert loaded.budget.limit == 50_000
      assert loaded.messages == state.messages
      # transient fields are reset on resume
      assert loaded.tool_calls == []
      assert loaded.last == nil
      assert loaded.stream_callback == nil
    end
  end

  describe "load/1 error handling" do
    test "returns a clean error for a missing session" do
      assert {:error, msg} = Checkpoint.load("does-not-exist")
      assert msg =~ "session not found"
    end

    test "returns an error instead of crashing on a corrupt mode", %{dir: dir} do
      write_raw(dir, "bad-mode", %{
        "version" => 1,
        "session_id" => "bad-mode",
        "task" => "t",
        "mode" => "wat",
        "iterations" => 0,
        "done" => false,
        "output" => nil,
        "budget" => %{"used" => 0, "limit" => 1},
        "messages" => []
      })

      assert {:error, msg} = Checkpoint.load("bad-mode")
      assert msg =~ "invalid mode"
    end

    test "rejects malformed messages (nil content)", %{dir: dir} do
      write_raw(dir, "bad-msgs", %{
        "version" => 1,
        "session_id" => "bad-msgs",
        "task" => "t",
        "mode" => "auto",
        "iterations" => 0,
        "done" => false,
        "output" => nil,
        "budget" => %{"used" => 0, "limit" => 1},
        "messages" => [%{"role" => "user"}]
      })

      assert {:error, msg} = Checkpoint.load("bad-msgs")
      assert msg =~ "malformed messages"
    end

    test "rejects an incompatible version", %{dir: dir} do
      write_raw(dir, "old", %{"version" => 99, "session_id" => "old", "mode" => "auto"})
      assert {:error, msg} = Checkpoint.load("old")
      assert msg =~ "incompatible checkpoint version"
    end
  end

  describe "list/0 and delete/1" do
    test "lists saved sessions and deletes one" do
      sid = Checkpoint.save(sample_state())

      assert Enum.any?(Checkpoint.list(), &(&1.session_id == sid))

      assert :ok = Checkpoint.delete(sid)
      refute Enum.any?(Checkpoint.list(), &(&1.session_id == sid))
    end
  end
end
