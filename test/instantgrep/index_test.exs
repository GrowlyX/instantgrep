defmodule Instantgrep.IndexTest do
  use ExUnit.Case

  alias Instantgrep.Index

  @test_dir "/tmp/instantgrep_test_#{:erlang.unique_integer([:positive])}"

  setup do
    File.mkdir_p!(@test_dir)

    File.write!(Path.join(@test_dir, "hello.txt"), "hello world\nfoo bar baz\n")
    File.write!(Path.join(@test_dir, "world.txt"), "world of code\nhello again\n")
    File.write!(Path.join(@test_dir, "empty.txt"), "")

    on_exit(fn ->
      File.rm_rf!(@test_dir)
    end)

    :ok
  end

  describe "build/1" do
    test "builds index from a directory" do
      index = Index.build(@test_dir)
      assert index.file_count >= 2
      assert index.trigram_count > 0
      assert index.build_time_us > 0
    end
  end

  describe "lookup/2" do
    test "returns file IDs containing a trigram" do
      index = Index.build(@test_dir)
      result = Index.lookup(index, "hel")
      assert MapSet.size(result) >= 1
    end

    test "returns empty set for unknown trigram" do
      index = Index.build(@test_dir)
      result = Index.lookup(index, "zzz")
      assert result == MapSet.new()
    end
  end

  describe "save/2 and load/1" do
    test "round-trips index through disk" do
      index = Index.build(@test_dir)
      assert :ok = Index.save(index, @test_dir)

      assert {:ok, loaded} = Index.load(@test_dir)
      assert loaded.file_count == index.file_count
      assert loaded.trigram_count == index.trigram_count
    end
  end

  describe "resolve_files/2" do
    test "resolves file IDs to paths" do
      index = Index.build(@test_dir)
      all = Index.all_files(index)
      assert length(all) >= 2
      assert Enum.all?(all, &String.starts_with?(&1, Path.expand(@test_dir)))
    end
  end
end
