defmodule Instantgrep.Index do
  @moduledoc """
  ETS-backed trigram inverted index with disk persistence.

  Builds a trigram index from a set of files using parallel workers.
  Each trigram maps to a list of `{file_id, next_mask, loc_mask}` postings.
  The index can be saved to and loaded from a `.instantgrep/` directory.
  """

  alias Instantgrep.{Native, Scanner}

  @type t :: %__MODULE__{
          postings_tables: tuple(),
          num_shards: pos_integer(),
          files_table: :ets.tid(),
          file_count: non_neg_integer(),
          trigram_count: non_neg_integer(),
          build_time_us: non_neg_integer(),
          file_metas: %{String.t() => {non_neg_integer(), integer(), non_neg_integer()}}
        }

  defstruct [
    :postings_tables,
    :num_shards,
    :files_table,
    :file_count,
    :trigram_count,
    :build_time_us,
    file_metas: %{}
  ]

  @index_dir ".instantgrep"
  @files_file "files.dat"
  @file_metas_file "file_metas.dat"
  @format_version 5

  defp shard_file(i), do: "postings_#{i}.dat"

  # Encode a 3-byte trigram binary as a 24-bit integer.
  # Integer keys are immediate BEAM values — no heap allocation on lookup.
  defp trigram_to_int(<<a, b, c>>), do: a * 65536 + b * 256 + c

  @doc """
  Build a trigram index from a directory path.

  Scans the directory for indexable files, extracts trigrams with masks,
  and constructs an ETS-backed inverted index.
  """
  @spec build(String.t(), keyword()) :: t()
  def build(path, opts \\ []) do
    start_time = System.monotonic_time(:microsecond)

    files = Scanner.scan(path, opts)

    # One shard per scheduler — workers route each trigram to its shard by hash,
    # so concurrent inserts to different shards never contend on the same stripe lock.
    num_shards = max(System.schedulers_online(), 1)

    postings_tables =
      for _ <- 1..num_shards do
        :ets.new(:instantgrep_postings, [
          :bag,
          :public,
          write_concurrency: true,
          read_concurrency: true
        ])
      end
      |> List.to_tuple()

    files_table = :ets.new(:instantgrep_files, [:set, :public, read_concurrency: true])

    # Bulk-insert all file mappings in one ETS call
    :ets.insert(files_table, files)

    # Parallel trigram extraction — each worker splits its rows across shards
    # by trigram hash (batch-insert per shard), reducing lock contention by num_shards.
    # Extraction workers return a stat entry alongside writing into ETS,
    # folding the file_metas collection into the same parallel pass.
    file_metas =
      files
      |> Task.async_stream(
        fn {file_id, file_path} ->
          stat_entry =
            case File.stat(file_path, time: :posix) do
              {:ok, %{mtime: mtime, size: size}} -> {file_path, {file_id, mtime, size}}
              _ -> nil
            end

          case File.read(file_path) do
            {:ok, content} ->
              sample = binary_part(content, 0, min(512, byte_size(content)))

              unless binary?(sample) do
                content
                |> Native.extract_trigrams()
                |> Enum.group_by(
                  fn {trigram, _nm, _lm} -> rem(:erlang.phash2(trigram), num_shards) end,
                  fn {trigram, nm, lm} -> {trigram, file_id, nm, lm} end
                )
                |> Enum.each(fn {shard, rows} ->
                  :ets.insert(elem(postings_tables, shard), rows)
                end)
              end

            {:error, _} ->
              :ok
          end

          stat_entry
        end,
        max_concurrency: num_shards * 2,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.flat_map(fn
        {:ok, nil} -> []
        {:ok, entry} -> [entry]
        _ -> []
      end)
      |> Map.new()

    elapsed = System.monotonic_time(:microsecond) - start_time

    # Count unique trigrams in parallel — one task per shard
    trigram_count =
      postings_tables
      |> Tuple.to_list()
      |> Task.async_stream(&count_unique_keys/1, ordered: false, timeout: :infinity)
      |> Enum.map(fn {:ok, n} -> n end)
      |> Enum.sum()

    %__MODULE__{
      postings_tables: postings_tables,
      num_shards: num_shards,
      files_table: files_table,
      file_count: length(files),
      trigram_count: trigram_count,
      build_time_us: elapsed,
      file_metas: file_metas
    }
  end

  @doc """
  Incrementally update an existing on-disk index by reindexing only files
  that have been added, modified, or deleted since the index was last built.

  Falls back to a full `build/2` when no prior `file_metas.dat` is found.
  Returns `{:ok, updated_index}`.
  """
  @spec update(String.t()) :: {:ok, t()}
  def update(base_dir) do
    case load(base_dir) do
      {:error, :not_found} ->
        IO.puts("No existing index found — performing full build...")
        index = build(base_dir)
        save(index, base_dir)
        {:ok, index}

      {:ok, %__MODULE__{file_metas: old_metas}} when map_size(old_metas) == 0 ->
        IO.puts("No file metadata in index — performing full rebuild...")
        index = build(base_dir)
        save(index, base_dir)
        {:ok, index}

      {:ok, %__MODULE__{file_metas: old_metas} = index} ->
        start_time = System.monotonic_time(:microsecond)

        # Re-scan directory for current file paths (no IDs yet)
        current_paths =
          Scanner.scan(base_dir, [])
          |> Enum.map(fn {_, path} -> path end)
          |> MapSet.new()

        old_paths = old_metas |> Map.keys() |> MapSet.new()

        removed = MapSet.difference(old_paths, current_paths)
        added = MapSet.difference(current_paths, old_paths)

        changed =
          MapSet.intersection(old_paths, current_paths)
          |> Enum.filter(fn path ->
            {_id, old_mtime, old_size} = old_metas[path]

            case File.stat(path, time: :posix) do
              {:ok, %{mtime: mtime, size: size}} -> mtime != old_mtime or size != old_size
              _ -> true
            end
          end)
          |> MapSet.new()

        unchanged = MapSet.size(current_paths) - MapSet.size(changed) - MapSet.size(added)

        IO.puts(
          "  #{MapSet.size(added)} added, #{MapSet.size(changed)} changed, " <>
            "#{MapSet.size(removed)} removed, #{unchanged} unchanged"
        )

        if Enum.all?([added, changed, removed], &(MapSet.size(&1) == 0)) do
          IO.puts("Index is already up to date.")
          {:ok, index}
        else
          # Remove postings for deleted/changed files
          to_remove = MapSet.union(changed, removed)
          ids_to_remove = Enum.map(to_remove, fn p -> elem(old_metas[p], 0) end)
          shard_list = Tuple.to_list(index.postings_tables)

          Enum.each(ids_to_remove, fn file_id ->
            Enum.each(shard_list, fn table ->
              :ets.match_delete(table, {:_, file_id, :_, :_})
            end)

            :ets.delete(index.files_table, file_id)
          end)

          # Assign new IDs for added/changed files (continue from highest existing ID)
          next_id =
            old_metas
            |> Map.values()
            |> Enum.map(fn {id, _, _} -> id end)
            |> then(fn ids -> if Enum.empty?(ids), do: 0, else: Enum.max(ids) + 1 end)

          to_reindex =
            MapSet.union(added, changed)
            |> Enum.sort()
            |> Enum.with_index(next_id)
            |> Enum.map(fn {path, id} -> {id, path} end)

          :ets.insert(index.files_table, to_reindex)

          num_shards = index.num_shards
          postings_tables = index.postings_tables

          to_reindex
          |> Task.async_stream(
            fn {file_id, file_path} ->
              case File.read(file_path) do
                {:ok, content} ->
                  sample = binary_part(content, 0, min(512, byte_size(content)))

                  unless binary?(sample) do
                    content
                    |> Native.extract_trigrams()
                    |> Enum.group_by(
                      fn {trigram, _nm, _lm} -> rem(:erlang.phash2(trigram), num_shards) end,
                      fn {trigram, nm, lm} -> {trigram, file_id, nm, lm} end
                    )
                    |> Enum.each(fn {shard, rows} ->
                      :ets.insert(elem(postings_tables, shard), rows)
                    end)
                  end

                {:error, _} ->
                  :ok
              end
            end,
            max_concurrency: num_shards * 2,
            ordered: false,
            timeout: :infinity
          )
          |> Stream.run()

          # Build updated file_metas: drop removed/changed, add new entries
          new_metas_delta =
            to_reindex
            |> Enum.flat_map(fn {id, path} ->
              case File.stat(path, time: :posix) do
                {:ok, %{mtime: mtime, size: size}} -> [{path, {id, mtime, size}}]
                _ -> []
              end
            end)
            |> Map.new()

          new_metas =
            old_metas
            |> Map.drop(MapSet.to_list(to_remove))
            |> Map.merge(new_metas_delta)

          trigram_count =
            index.postings_tables
            |> Tuple.to_list()
            |> Task.async_stream(&count_unique_keys/1, ordered: false, timeout: :infinity)
            |> Enum.map(fn {:ok, n} -> n end)
            |> Enum.sum()

          elapsed = System.monotonic_time(:microsecond) - start_time

          updated_index = %{
            index
            | file_count: map_size(new_metas),
              trigram_count: trigram_count,
              build_time_us: elapsed,
              file_metas: new_metas
          }

          save(updated_index, base_dir)
          {:ok, updated_index}
        end
    end
  end

  @doc """
  Query the index with a list of trigrams. Returns a `MapSet` of file IDs
  whose documents contain the given trigram.
  """
  @spec lookup(t(), binary()) :: MapSet.t(non_neg_integer())
  def lookup(%__MODULE__{postings_tables: tables, num_shards: n}, trigram) do
    key = trigram_to_int(trigram)

    tables
    |> elem(rem(:erlang.phash2(key), n))
    |> :ets.lookup(key)
    |> MapSet.new(fn {_key, file_id, _next_mask, _loc_mask} -> file_id end)
  end

  @doc """
  Query the index with a trigram, returning `%{file_id => {next_mask, loc_mask}}`.

  Used by mask-aware query evaluation to pre-filter candidate files using
  bloom-filter masks before looking up subsequent consecutive trigrams.
  """
  @spec lookup_with_masks(t(), binary()) ::
          %{non_neg_integer() => {non_neg_integer(), non_neg_integer()}}
  def lookup_with_masks(%__MODULE__{postings_tables: tables, num_shards: n}, trigram) do
    key = trigram_to_int(trigram)

    tables
    |> elem(rem(:erlang.phash2(key), n))
    |> :ets.lookup(key)
    |> Map.new(fn {_key, file_id, next_mask, loc_mask} -> {file_id, {next_mask, loc_mask}} end)
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
  def save(%__MODULE__{postings_tables: pts, files_table: ft} = index, base_dir) do
    dir = Path.join(base_dir, @index_dir)
    File.mkdir_p!(dir)

    meta = %{
      file_count: index.file_count,
      trigram_count: index.trigram_count,
      build_time_us: index.build_time_us,
      num_shards: index.num_shards,
      format_version: @format_version
    }

    # Write meta + files table (+ file_metas if present)
    # Use compression level 1 (fastest) — reduces write time by ~3x vs default
    # level 6 at only ~10-15% larger files.
    t_meta =
      Task.async(fn ->
        File.write!(Path.join(dir, "meta.dat"), :erlang.term_to_binary(meta))

        File.write!(
          Path.join(dir, @files_file),
          :erlang.term_to_binary(:ets.tab2list(ft), [{:compressed, 1}])
        )

        if map_size(index.file_metas) > 0 do
          File.write!(
            Path.join(dir, @file_metas_file),
            :erlang.term_to_binary(index.file_metas, [{:compressed, 1}])
          )
        end
      end)

    # Write each shard as its own compressed file — enables parallel load with no re-sharding.
    shard_tasks =
      pts
      |> Tuple.to_list()
      |> Enum.with_index()
      |> Enum.map(fn {table, i} ->
        Task.async(fn ->
          File.write!(
            Path.join(dir, shard_file(i)),
            :erlang.term_to_binary(:ets.tab2list(table), [{:compressed, 1}])
          )
        end)
      end)

    [t_meta | shard_tasks] |> Enum.each(&Task.await(&1, :infinity))
    :ok
  end

  @doc """
  Load a previously saved index from disk.
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, :not_found}
  def load(base_dir) do
    dir = Path.join(base_dir, @index_dir)
    meta_path = Path.join(dir, "meta.dat")
    files_path = Path.join(dir, @files_file)

    if File.regular?(meta_path) and File.regular?(files_path) do
      case meta_path |> File.read!() |> :erlang.binary_to_term() do
        %{format_version: @format_version, num_shards: num_shards} = meta ->
          shard_paths = for i <- 0..(num_shards - 1), do: Path.join(dir, shard_file(i))

          if Enum.all?(shard_paths, &File.regular?/1) do
            # Allocate all shard tables up front
            postings_tables =
              for _ <- 0..(num_shards - 1) do
                :ets.new(:instantgrep_postings, [
                  :bag,
                  :public,
                  write_concurrency: true,
                  read_concurrency: true
                ])
              end
              |> List.to_tuple()

            # Load each shard file in parallel — no group_by, direct insert
            shard_paths
            |> Enum.with_index()
            |> Task.async_stream(
              fn {path, i} ->
                rows = path |> File.read!() |> :erlang.binary_to_term()
                :ets.insert(elem(postings_tables, i), rows)
              end,
              max_concurrency: num_shards,
              ordered: false,
              timeout: :infinity
            )
            |> Stream.run()

            files_data = files_path |> File.read!() |> :erlang.binary_to_term()
            files_table = :ets.new(:instantgrep_files, [:set, :public, read_concurrency: true])
            :ets.insert(files_table, files_data)

            metas_path = Path.join(dir, @file_metas_file)

            file_metas =
              if File.regular?(metas_path) do
                metas_path |> File.read!() |> :erlang.binary_to_term()
              else
                %{}
              end

            {:ok,
             %__MODULE__{
               postings_tables: postings_tables,
               num_shards: num_shards,
               files_table: files_table,
               file_count: meta.file_count,
               trigram_count: meta.trigram_count,
               build_time_us: meta.build_time_us,
               file_metas: file_metas
             }}
          else
            {:error, :not_found}
          end

        _ ->
          {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Print index statistics.
  """
  @spec stats(t()) :: :ok
  def stats(%__MODULE__{} = index) do
    IO.puts("Index Statistics:")
    IO.puts("  Files indexed:   #{index.file_count}")
    IO.puts("  Unique trigrams: #{index.trigram_count}")
    IO.puts("  Shards:          #{index.num_shards}")
    IO.puts("  Build time:      #{format_time(index.build_time_us)}")
    :ok
  end

  # Count unique keys in a :bag table using first/next (which iterates unique keys, not objects)
  defp count_unique_keys(table), do: count_unique_keys(table, :ets.first(table), 0)
  defp count_unique_keys(_table, :"$end_of_table", n), do: n

  defp count_unique_keys(table, key, n),
    do: count_unique_keys(table, :ets.next(table, key), n + 1)

  defp binary?(data) when byte_size(data) == 0, do: false

  defp binary?(data) do
    # Null byte presence is a reliable indicator of binary content
    :binary.match(data, <<0>>) != :nomatch
  end

  defp format_time(us) when us < 1_000, do: "#{us}µs"
  defp format_time(us) when us < 1_000_000, do: "#{Float.round(us / 1_000, 1)}ms"
  defp format_time(us), do: "#{Float.round(us / 1_000_000, 2)}s"
end
