defmodule MiniAgent.Tools.SandboxTest do
  use ExUnit.Case, async: true

  alias MiniAgent.Tools.Sandbox

  setup do
    root = Path.join(System.tmp_dir!(), "sandbox_test_#{System.unique_integer([:positive])}")
    ws = Path.join(root, "ws")
    sibling = Path.join(root, "ws_evil")
    File.mkdir_p!(ws)
    File.mkdir_p!(sibling)

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root, ws: ws, sibling: sibling}
  end

  describe "confine/2 - allowed paths" do
    test "permits the workspace root itself", %{ws: ws} do
      assert {:ok, _} = Sandbox.confine(ws, ws)
    end

    test "permits a relative path inside the workspace", %{ws: ws} do
      assert {:ok, path} = Sandbox.confine("sub/file.txt", ws)
      assert path == Path.join(ws, "sub/file.txt")
    end

    test "permits an absolute path inside the workspace", %{ws: ws} do
      target = Path.join(ws, "a.txt")
      assert {:ok, ^target} = Sandbox.confine(target, ws)
    end
  end

  describe "confine/2 - escapes (security regression)" do
    test "rejects a relative ../ traversal", %{ws: ws} do
      assert {:error, :outside_workspace} = Sandbox.confine("../../etc/passwd", ws)
    end

    test "rejects an absolute path outside the workspace", %{ws: ws} do
      assert {:error, :outside_workspace} = Sandbox.confine("/etc/passwd", ws)
    end

    test "rejects a sibling directory sharing the workspace name prefix", %{
      ws: ws,
      sibling: sibling
    } do
      # The original prefix-match bug accepted /root/ws_evil for workspace /root/ws.
      escaped = Path.join(sibling, "secret.txt")
      assert {:error, :outside_workspace} = Sandbox.confine(escaped, ws)
      assert {:error, :outside_workspace} = Sandbox.confine("../ws_evil/secret.txt", ws)
    end

    test "rejects a symlink inside the workspace pointing outside", %{ws: ws, root: root} do
      outside = Path.join(root, "outside.txt")
      File.write!(outside, "secret")
      link = Path.join(ws, "link.txt")
      File.ln_s!(outside, link)

      assert {:error, :outside_workspace} = Sandbox.confine(link, ws)
    end
  end

  describe "arg_escapes?/2" do
    test "flags and non-path arguments are safe", %{ws: ws} do
      refute Sandbox.arg_escapes?("-l", ws)
      refute Sandbox.arg_escapes?("pattern", ws)
      refute Sandbox.arg_escapes?("sub/file.txt", ws)
    end

    test "detects a traversal argument", %{ws: ws} do
      assert Sandbox.arg_escapes?("../../etc/passwd", ws)
    end

    test "detects an absolute outside argument", %{ws: ws} do
      assert Sandbox.arg_escapes?("/etc/passwd", ws)
    end
  end
end
