defmodule MiniAgent.PermissionTest do
  use ExUnit.Case, async: true

  alias MiniAgent.Permission

  describe ":auto mode" do
    test "always allows safe tools" do
      assert Permission.check("read_file", %{"path" => "."}, :auto) == :allow
    end

    test "always allows dangerous tools" do
      assert Permission.check("write_file", %{"path" => "x", "content" => "y"}, :auto) == :allow
      assert Permission.check("shell", %{"command" => "ls"}, :auto) == :allow
    end
  end

  describe ":readonly mode" do
    test "allows safe tools" do
      assert Permission.check("read_file", %{}, :readonly) == :allow
      assert Permission.check("list_dir", %{}, :readonly) == :allow
    end

    test "denies write_file" do
      assert {:deny, _reason} = Permission.check("write_file", %{}, :readonly)
    end

    test "denies shell" do
      assert {:deny, _reason} = Permission.check("shell", %{}, :readonly)
    end
  end
end
