defmodule MiniAgent.ToolsTest do
  use ExUnit.Case, async: true

  alias MiniAgent.Tools

  describe "definitions/0" do
    test "returns a non-empty list" do
      assert match?([_ | _], Tools.definitions())
    end

    test "each entry has required Anthropic schema keys" do
      for tool <- Tools.definitions() do
        assert is_binary(tool.name)
        assert is_binary(tool.description)
        assert is_map(tool.input_schema)
      end
    end
  end

  describe "dangerous?/1" do
    test "write_file is dangerous" do
      assert Tools.dangerous?("write_file")
    end

    test "shell is dangerous" do
      assert Tools.dangerous?("shell")
    end

    test "read_file is not dangerous" do
      refute Tools.dangerous?("read_file")
    end

    test "list_dir is not dangerous" do
      refute Tools.dangerous?("list_dir")
    end
  end

  describe "execute/3 - unknown tool" do
    test "returns error string for unknown tool" do
      result = Tools.execute("nonexistent_tool", %{}, :auto)
      assert result =~ "Error"
      assert result =~ "nonexistent_tool"
    end
  end

  describe "execute/3 - list_dir" do
    test "lists tmp directory" do
      result = Tools.execute("list_dir", %{"path" => System.tmp_dir!()}, :auto)
      assert is_binary(result)
    end
  end

  describe "execute/3 - read_file" do
    test "reads an existing file" do
      path = Path.join(System.tmp_dir!(), "mini_agent_test_read_#{System.unique_integer()}.txt")
      File.write!(path, "hello content")

      result = Tools.execute("read_file", %{"path" => path}, :auto)
      assert result =~ "hello content"

      File.rm!(path)
    end

    test "returns error for missing file" do
      result =
        Tools.execute("read_file", %{"path" => "/tmp/mini_agent_nonexistent_file.txt"}, :auto)

      assert result =~ "Error"
    end

    test "returns truncation hint and allows paging with offset" do
      path = Path.join(System.tmp_dir!(), "mini_agent_test_large_#{System.unique_integer()}.txt")
      # Write more than 4000 bytes
      large = String.duplicate("x", 5_000)
      File.write!(path, large)

      first = Tools.execute("read_file", %{"path" => path}, :auto)
      assert first =~ "[truncated"
      assert first =~ "use offset: 4000"

      second = Tools.execute("read_file", %{"path" => path, "offset" => 4000}, :auto)
      assert byte_size(second) == 1_000
      refute second =~ "[truncated"

      File.rm!(path)
    end
  end

  describe "execute/3 - write_file" do
    test "writes and reads back content" do
      path = Path.join(System.tmp_dir!(), "mini_agent_test_write_#{System.unique_integer()}.txt")

      write_result =
        Tools.execute("write_file", %{"path" => path, "content" => "test data"}, :auto)

      assert write_result =~ "Wrote"

      assert File.read!(path) == "test data"
      File.rm!(path)
    end
  end
end
