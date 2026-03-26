defmodule Instantgrep.TrigramTest do
  use ExUnit.Case, async: true
  doctest Instantgrep.Trigram

  alias Instantgrep.Trigram

  describe "extract/1" do
    test "extracts overlapping trigrams from a string" do
      result = Trigram.extract("hello")
      assert MapSet.member?(result, "hel")
      assert MapSet.member?(result, "ell")
      assert MapSet.member?(result, "llo")
      assert MapSet.size(result) == 3
    end

    test "returns empty set for strings shorter than 3 bytes" do
      assert Trigram.extract("hi") == MapSet.new()
      assert Trigram.extract("a") == MapSet.new()
      assert Trigram.extract("") == MapSet.new()
    end

    test "handles exact 3-byte string" do
      result = Trigram.extract("abc")
      assert result == MapSet.new(["abc"])
    end

    test "deduplicates repeated trigrams" do
      result = Trigram.extract("aaaa")
      assert result == MapSet.new(["aaa"])
    end
  end

  describe "extract_with_masks/1" do
    test "returns map with integer trigram keys and mask tuples" do
      result = Trigram.extract_with_masks("hello")
      assert is_map(result)

      # "hel" as integer: ?h * 65536 + ?e * 256 + ?l
      hel_key = ?h * 65536 + ?e * 256 + ?l
      assert Map.has_key?(result, hel_key)
      {next_mask, loc_mask} = Map.get(result, hel_key)
      assert is_integer(next_mask)
      assert is_integer(loc_mask)
      assert next_mask >= 0 and next_mask <= 255
      assert loc_mask >= 0 and loc_mask <= 255
    end

    test "loc_mask encodes position mod 8" do
      # "abcabc" -> "abc" at positions 0 and 3
      result = Trigram.extract_with_masks("abcabc")
      abc_key = ?a * 65536 + ?b * 256 + ?c
      {_next, loc_mask} = Map.get(result, abc_key)
      # Position 0 -> bit 0, position 3 -> bit 3
      assert Bitwise.band(loc_mask, 1) == 1
      assert Bitwise.band(loc_mask, 8) == 8
    end

    test "next_mask encodes following character" do
      result = Trigram.extract_with_masks("abcd")
      abc_key = ?a * 65536 + ?b * 256 + ?c
      {next_mask, _loc} = Map.get(result, abc_key)
      # 'd' follows "abc", hash bit = 1 << (ord('d') & 7) = 1 << 4 = 16
      expected_bit = Bitwise.bsl(1, Bitwise.band(?d, 7))
      assert Bitwise.band(next_mask, expected_bit) == expected_bit
    end
  end

  describe "extract_ordered/1" do
    test "returns trigrams in order" do
      result = Trigram.extract_ordered("abcde")
      assert result == ["abc", "bcd", "cde"]
    end

    test "returns empty list for short strings" do
      assert Trigram.extract_ordered("ab") == []
    end
  end
end
