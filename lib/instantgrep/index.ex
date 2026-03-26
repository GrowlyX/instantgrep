defmodule Instantgrep.Index do
  @moduledoc """
  ETS-backed trigram inverted index with disk persistence.

  Builds a trigram index from a set of files using parallel workers.
  Each trigram maps to a list of `{file_id, next_mask, loc_mask}` postings.
  The index can be saved to and loaded from a `.instantgrep/` directory.
  """

  alias Instantgrep.{Scanner, Trigram}

  @type t :: %__MODULE__{
          postings_table: :ets.tid(),
          files_table: :ets.tid(),
          file_count: non_neg_integer(),
          trigram_count: non_neg_integer(),
          build_time_us: non_neg_integer()
        }

  defstruct [:postings_table, :files_table, :file_count, :trigram_count, :build_time_us]

  @index_dir ".instantgrep"
  @postings_file "postings.dat"
  @files_file "files.dat"

  @doc """
  Build a trigram index from a directory path.

  Scans the directory for indexable files, extracts trigrams with masks,
  and constructs an ETS-backed inverted index.
  """
  @spec build(String.t(), keyword()) :: t()
  def build(path, opts \\ []) do
    start_time = System.monotonic_time(:microsecond)

    files = Scanner.scan(path, opts)

    postings_table = :ets.new(:instantgrep_postings, [:set, :public, read_concurrency: true])
    files_table = :ets.new(:instantgrep_files, [:set, :public, read_concurrency: true])

    # Store file mappings
    Enum.each(files, fn {file_id, file_path} ->
      :ets.insert(files_table, {file_id, file_path})
    end)

    # Parallel trigram extraction
    files
    |> Task.async_stream(
      fn {file_id, file_path} ->
        case File.read(file_path) do
          {:ok, content} ->
            masks = Trigram.extract_with_masks(content)
            {file_id, masks}

          {:error, _} ->
            {file_id, %{}}
        end
      end,
      max_concurrency: System.schedulers_online() * 2,
      ordered: false,
      timeout: 30_000
    )
    |> Enum.each(fn {:ok, {file_id, masks}} ->
      Enum.each(masks, fn {trigram, {next_mask, loc_mask}} ->
        case :ets.lookup(postings_table, trigram) do
          [{^trigram, postings}] ->
            :ets.insert(postings_table, {trigram, [{file_id, next_mask, loc_mask} | postings]})

          [] ->
            :ets.insert(postings_table, {trigram, [{file_id, next_mask, loc_mask}]})
        end
      end)
    end)

    elapsed = System.monotonic_time(:microsecond) - start_time
    trigram_count = :ets.info(postings_table, :size)

    %__MODULE__{
      postings_table: postings_table,
      files_table: files_table,
      file_count: length(files),
      trigram_count: trigram_count,
      build_time_us: elapsed
    }
  end

  @doc """
  Query the index with a list of trigrams. Returns a `MapSet` of file IDs
  whose documents contain the given trigram.
  """
  @spec lookup(t(), binary()) :: MapSet.t(non_neg_integer())
  def lookup(%__MODULE__{postings_table: table}, trigram) do
    case :ets.lookup(table, trigram) do
      [{^trigram, postings}] ->
        postings
        |> Enum.map(fn {file_id, _next, _loc} -> file_id end)
        |> MapSet.new()

      [] ->
        MapSet.new()
    end
  end

  @doc """
  Resolve file IDs to file paths.
  """
  @spec resolve_files(t(), MapSet.t(non_neg_integer()) | :all) :: [String.t()]
  def resolve_files(%__MODULE__{files_table: table, file_count: count}, :all) do
    for id <- 0..(count - 1),
        [{^id, path}] = :ets.lookup(table, id) do
      path
    end
  end

  def resolve_files(%__MODULE__{files_table: table}, file_ids) do
    file_ids
    |> Enum.flat_map(fn id ->
      case :ets.lookup(table, id) do
        [{^id, path}] -> [path]
        [] -> []
      end
    end)
    |> Enum.sort()
  end

  @doc """
  Return all indexed file paths.
  """
  @spec all_files(t()) :: [String.t()]
  def all_files(%__MODULE__{} = index) do
    resolve_files(index, :all)
  end

  @doc """
  Save the index to disk in the given base directory.
  """
  @spec save(t(), String.t()) :: :ok
  def save(%__MODULE__{postings_table: pt, files_table: ft} = index, base_dir) do
    dir = Path.join(base_dir, @index_dir)
    File.mkdir_p!(dir)

    postings_data = :ets.tab2list(pt)
    files_data = :ets.tab2list(ft)

    meta = %{
      file_count: index.file_count,
      trigram_count: index.trigram_count,
      build_time_us: index.build_time_us
    }

    File.write!(Path.join(dir, @postings_file), :erlang.term_to_binary({postings_data, meta}))
    File.write!(Path.join(dir, @files_file), :erlang.term_to_binary(files_data))

    :ok
  end

  @doc """
  Load a previously saved index from disk.
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, :not_found}
  def load(base_dir) do
    dir = Path.join(base_dir, @index_dir)
    postings_path = Path.join(dir, @postings_file)
    files_path = Path.join(dir, @files_file)

    if File.regular?(postings_path) and File.regular?(files_path) do
      {postings_data, meta} =
        postings_path |> File.read!() |> :erlang.binary_to_term()

      files_data =
        files_path |> File.read!() |> :erlang.binary_to_term()

      postings_table = :ets.new(:instantgrep_postings, [:set, :public, read_concurrency: true])
      files_table = :ets.new(:instantgrep_files, [:set, :public, read_concurrency: true])

      :ets.insert(postings_table, postings_data)
      :ets.insert(files_table, files_data)

      {:ok,
       %__MODULE__{
         postings_table: postings_table,
         files_table: files_table,
         file_count: meta.file_count,
         trigram_count: meta.trigram_count,
         build_time_us: meta.build_time_us
       }}
    else
      {:error, :not_found}
    end
  end

  @doc """
  Format index statistics as a string.
  """
  @spec stats(t()) :: String.t()
  def stats(%__MODULE__{} = index) do
    """
    Index Statistics:
      Files indexed:   #{index.file_count}
      Unique trigrams: #{index.trigram_count}
      Build time:      #{format_time(index.build_time_us)}
    """
    |> String.trim_trailing()
  end

  defp format_time(us) when us < 1_000, do: "#{us}µs"
  defp format_time(us) when us < 1_000_000, do: "#{Float.round(us / 1_000, 1)}ms"
  defp format_time(us), do: "#{Float.round(us / 1_000_000, 2)}s"
end
