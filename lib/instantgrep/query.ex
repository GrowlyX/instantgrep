defmodule Instantgrep.Query do
  @moduledoc """
  Decomposes regex patterns into trigram query trees for index lookup.

  Parses a regex string and extracts the trigrams that must be present in any
  matching document. Returns a query tree of AND/OR conditions that can be
  evaluated against the trigram inverted index.

  ## Query Tree Format

  - `{:all, [trigrams]}` — all trigrams must be present (intersection)
  - `{:any, [query_trees]}` — at least one branch must match (union)
  - `:none` — no trigrams extractable, must scan all files
  """

  alias Instantgrep.Trigram

  @type query_tree :: {:all, [binary()]} | {:any, [query_tree()]} | :none

  @doc """
  Decompose a regex pattern string into a trigram query tree.

  ## Examples

      iex> Instantgrep.Query.decompose("hello")
      {:all, ["hel", "ell", "llo"]}

      iex> Instantgrep.Query.decompose("cat|dog")
      {:any, [{:all, ["cat"]}, {:all, ["dog"]}]}

      iex> Instantgrep.Query.decompose(".*")
      :none

  """
  @spec decompose(binary()) :: query_tree()
  def decompose(pattern) when is_binary(pattern) do
    pattern
    |> split_alternations()
    |> build_query_tree()
  end

  @doc """
  Evaluate a query tree against an index query function.

  The query function takes a trigram and returns a `MapSet` of file IDs.
  Returns the set of candidate file IDs that could match.
  """
  @spec evaluate(query_tree(), (binary() -> MapSet.t())) :: MapSet.t() | :all
  def evaluate(:none, _query_fn), do: :all

  def evaluate({:all, trigrams}, query_fn) do
    trigrams
    |> Enum.map(query_fn)
    |> Enum.reduce(fn set, acc ->
      MapSet.intersection(acc, set)
    end)
  end

  def evaluate({:any, branches}, query_fn) do
    branches
    |> Enum.map(&evaluate(&1, query_fn))
    |> Enum.reduce(fn
      :all, _acc -> :all
      _set, :all -> :all
      set, acc -> MapSet.union(acc, set)
    end)
  end

  @doc """
  Evaluate a query tree using mask-aware lookup for enhanced pre-filtering.

  For `:all` chains of consecutive trigrams, uses the `next_mask` from each
  posting to pre-filter candidates before looking up the next trigram — reducing
  redundant ETS lookups on trigram pairs that cannot be adjacent in any document.

  The query function must return `%{file_id => {next_mask, loc_mask}}`.
  """
  @spec evaluate_masked(
          query_tree(),
          (binary() -> %{non_neg_integer() => {non_neg_integer(), non_neg_integer()}})
        ) :: MapSet.t() | :all
  def evaluate_masked(:none, _query_fn), do: :all

  def evaluate_masked({:all, []}, _query_fn), do: MapSet.new()

  def evaluate_masked({:all, [first | rest]}, query_fn) do
    first_map = query_fn.(first)

    {final_map, _} =
      Enum.reduce(rest, {first_map, first}, fn trigram, {candidates, _prev} ->
        # next_mask for trigram T at position p stores: bsl(1, band(char_at_p+3, 7))
        # char_at_p+3 is the 4th character starting at p, which equals the LAST byte
        # of the next overlapping trigram T' (which starts at p+1, so T'[2] = char_at_p+3).
        # We must use last_byte of T', NOT first_byte.
        <<_, _, last_byte>> = trigram
        next_bit = Bitwise.bsl(1, Bitwise.band(last_byte, 7))

        pre_filtered_ids =
          candidates
          |> Enum.filter(fn {_id, {next_mask, _loc}} ->
            Bitwise.band(next_mask, next_bit) != 0
          end)
          |> MapSet.new(fn {id, _} -> id end)

        current_map =
          query_fn.(trigram)
          |> Map.filter(fn {id, _} -> MapSet.member?(pre_filtered_ids, id) end)

        {current_map, trigram}
      end)

    MapSet.new(Map.keys(final_map))
  end

  def evaluate_masked({:any, branches}, query_fn) do
    branches
    |> Enum.map(&evaluate_masked(&1, query_fn))
    |> Enum.reduce(fn
      :all, _acc -> :all
      _set, :all -> :all
      set, acc -> MapSet.union(acc, set)
    end)
  end

  # --- Private: Alternation Splitting ---

  # Split on top-level `|` (outside of parens/brackets)
  defp split_alternations(pattern) do
    do_split_alternations(pattern, 0, 0, <<>>, [])
  end

  defp do_split_alternations(<<>>, _paren, _bracket, current, acc) do
    Enum.reverse([current | acc])
  end

  defp do_split_alternations(<<"\\", c, rest::binary>>, paren, bracket, current, acc) do
    do_split_alternations(rest, paren, bracket, <<current::binary, "\\", c>>, acc)
  end

  defp do_split_alternations(<<"(", rest::binary>>, paren, bracket, current, acc) do
    do_split_alternations(rest, paren + 1, bracket, <<current::binary, "(">>, acc)
  end

  defp do_split_alternations(<<")", rest::binary>>, paren, bracket, current, acc) do
    do_split_alternations(rest, max(paren - 1, 0), bracket, <<current::binary, ")">>, acc)
  end

  defp do_split_alternations(<<"[", rest::binary>>, paren, _bracket, current, acc) do
    do_split_alternations(rest, paren, 1, <<current::binary, "[">>, acc)
  end

  defp do_split_alternations(<<"]", rest::binary>>, paren, _bracket, current, acc) do
    do_split_alternations(rest, paren, 0, <<current::binary, "]">>, acc)
  end

  defp do_split_alternations(<<"|", rest::binary>>, 0, 0, current, acc) do
    do_split_alternations(rest, 0, 0, <<>>, [current | acc])
  end

  defp do_split_alternations(<<c, rest::binary>>, paren, bracket, current, acc) do
    do_split_alternations(rest, paren, bracket, <<current::binary, c>>, acc)
  end

  # --- Private: Query Tree Building ---

  defp build_query_tree([single]) do
    extract_from_branch(single)
  end

  defp build_query_tree(branches) do
    trees = Enum.map(branches, &extract_from_branch/1)

    if Enum.any?(trees, &(&1 == :none)) do
      :none
    else
      {:any, trees}
    end
  end

  # Extract trigrams from a single branch (no top-level alternation)
  defp extract_from_branch(branch) do
    literals = extract_literals(branch)
    trigrams = literals |> Enum.flat_map(&Trigram.extract_ordered/1) |> Enum.uniq()

    case trigrams do
      [] -> :none
      _ -> {:all, trigrams}
    end
  end

  @doc false
  @spec extract_literals(binary()) :: [binary()]
  def extract_literals(pattern) do
    do_extract_literals(pattern, <<>>, [])
  end

  # Walk through the pattern character by character, collecting literal segments.
  # Break on metacharacters and syntax that can match variable content.
  defp do_extract_literals(<<>>, current, acc) do
    finalize_literals(current, acc)
  end

  # Escaped characters — the character after \ is literal
  defp do_extract_literals(<<"\\", c, rest::binary>>, current, acc)
       when c in ~c[wWdDsStbnrfv] do
    # These are character class escapes — break the literal chain
    acc = finalize_literals(current, acc)
    do_extract_literals(rest, <<>>, acc)
  end

  defp do_extract_literals(<<"\\", c, rest::binary>>, current, acc) do
    do_extract_literals(rest, <<current::binary, c>>, acc)
  end

  # Character classes — break literals, skip content inside brackets
  defp do_extract_literals(<<"[", rest::binary>>, current, acc) do
    acc = finalize_literals(current, acc)
    rest = skip_char_class(rest)
    do_extract_literals(rest, <<>>, acc)
  end

  # Quantifiers — they modify the preceding character, so remove it from current literal
  defp do_extract_literals(<<q, rest::binary>>, current, acc) when q in ~c[*+?] do
    # Remove the last character from current (it's being quantified)
    trimmed =
      if byte_size(current) > 0 do
        binary_part(current, 0, byte_size(current) - 1)
      else
        current
      end

    acc = finalize_literals(trimmed, acc)
    do_extract_literals(rest, <<>>, acc)
  end

  # Dot (wildcard), caret, dollar — break the chain
  defp do_extract_literals(<<c, rest::binary>>, current, acc) when c in ~c[.^$] do
    acc = finalize_literals(current, acc)
    do_extract_literals(rest, <<>>, acc)
  end

  # Grouping parens — break (they may contain alternation or quantifiers)
  defp do_extract_literals(<<c, rest::binary>>, current, acc) when c in ~c[()] do
    acc = finalize_literals(current, acc)
    do_extract_literals(rest, <<>>, acc)
  end

  # Curly brace quantifiers {n,m} — break
  defp do_extract_literals(<<"{", rest::binary>>, current, acc) do
    trimmed =
      if byte_size(current) > 0 do
        binary_part(current, 0, byte_size(current) - 1)
      else
        current
      end

    acc = finalize_literals(trimmed, acc)
    rest = skip_until(rest, "}")
    do_extract_literals(rest, <<>>, acc)
  end

  # Regular literal character
  defp do_extract_literals(<<c, rest::binary>>, current, acc) do
    do_extract_literals(rest, <<current::binary, c>>, acc)
  end

  defp finalize_literals(<<>>, acc), do: acc
  defp finalize_literals(current, acc), do: [current | acc]

  defp skip_char_class(<<"\\", _, rest::binary>>), do: skip_char_class(rest)
  defp skip_char_class(<<"]", rest::binary>>), do: rest
  defp skip_char_class(<<_, rest::binary>>), do: skip_char_class(rest)
  defp skip_char_class(<<>>), do: <<>>

  defp skip_until(<<c, rest::binary>>, <<c>>) when is_binary(rest), do: rest
  defp skip_until(<<_, rest::binary>>, target), do: skip_until(rest, target)
  defp skip_until(<<>>, _target), do: <<>>
end
