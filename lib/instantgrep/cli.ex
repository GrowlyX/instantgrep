defmodule Instantgrep.CLI do
  @moduledoc """
  Main CLI entry point for the instantgrep escript.

  Usage:
      instantgrep [OPTIONS] PATTERN [PATH]

  Options:
      --build          Build/rebuild index only (no search)
      --update         Update index (reindex only changed/new/deleted files)
      --stop           Stop a running daemon
      --no-index       Skip index, brute-force scan (like grep)
      -i, --ignore-case   Case-insensitive matching
      --stats          Show index statistics
      --time           Print per-phase timing to stderr
      -h, --help       Show this help message

  Examples:
      instantgrep --build .                # build index
      instantgrep --update .               # incremental update (changed files only)
      instantgrep "pattern" .              # search (uses daemon if running, else direct)
      instantgrep --stop .                 # stop running daemon
      instantgrep -i "todo|fixme" src/
      instantgrep --no-index "pattern" .   # brute-force, no index
      instantgrep --time "pattern" .       # show per-phase timing
  """

  alias Instantgrep.{Index, Matcher, Query}

  @doc false
  @spec main([String.t()]) :: :ok
  def main(args) do
    %{daemon: daemon} = parsed = parse_args(args)

    if daemon do
      Instantgrep.Daemon.start_server()
    else
      case execute(parsed) do
        {:ok, output} ->
          if output != "", do: IO.puts(output)
          System.halt(0)

        {:error, code, msg} ->
          IO.puts(:stderr, msg)
          System.halt(code)
      end
    end
  end

  # --- Argument Parsing ---

  @doc false
  def parse_args(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          build: :boolean,
          update: :boolean,
          stop: :boolean,
          no_index: :boolean,
          ignore_case: :boolean,
          stats: :boolean,
          time: :boolean,
          daemon: :boolean,
          help: :boolean
        ],
        aliases: [i: :ignore_case, h: :help]
      )

    build  = Keyword.get(opts, :build,  false)
    update = Keyword.get(opts, :update, false)
    stop   = Keyword.get(opts, :stop,   false)
    stats  = Keyword.get(opts, :stats,  false)

    # For --build / --update / --stats / --stop, positional[0] is the directory.
    # For search, positional[0] is the pattern and positional[1] is the path.
    {pattern, path} =
      if build or update or stats or stop do
        {nil, Enum.at(positional, 0, ".")}
      else
        {Enum.at(positional, 0), Enum.at(positional, 1, ".")}
      end

    %{
      build: build,
      update: update,
      stop: stop,
      no_index: Keyword.get(opts, :no_index, false),
      ignore_case: Keyword.get(opts, :ignore_case, false),
      stats: stats,
      time: Keyword.get(opts, :time, false),
      daemon: Keyword.get(opts, :daemon, false),
      help: Keyword.get(opts, :help, false),
      pattern: pattern,
      path: path
    }
  end

  # --- Command Execution ---

  @doc false
  def execute(%{help: true}) do
    {:ok, @moduledoc}
  end

  def execute(%{build: true, path: path}) do
    IO.puts("Building index for #{path}...")
    index = Index.build(path)
    Index.save(index, path)
    Index.stats(index)
    {:ok, "Index saved to #{Path.join(path, ".instantgrep")}/"}
  end

  def execute(%{update: true, path: path}) do
    IO.puts("Updating index for #{path}...")
    {:ok, index} = Index.update(path)
    Index.stats(index)
    {:ok, ""}
  end

  def execute(%{stop: true, path: _path}) do
    {:ok, "Stop not supported in this daemon mode. Kill the daemon process directly."}
  end

  def execute(%{stats: true, path: path}) do
    case Index.load(path) do
      {:ok, index} ->
        Index.stats(index)
        {:ok, ""}

      {:error, :not_found} ->
        {:error, 1, "No index found. Run: instantgrep --build #{path}"}
    end
  end

  def execute(%{pattern: nil}) do
    {:error, 1, "Error: no pattern specified. Run: instantgrep --help"}
  end

  def execute(%{no_index: true} = args) do
    execute_brute_force(args)
  end

  def execute(args) do
    execute_indexed(args)
  end

  defp execute_indexed(%{pattern: pattern, path: path, ignore_case: ignore_case, time: show_time}) do
    case compile_regex(pattern, ignore_case) do
      {:ok, regex} ->
        execute_indexed_direct(pattern, path, ignore_case, show_time, regex)

      {:error, msg} ->
        {:error, 1, msg}
    end
  end

  # Fallback for callers that don't pass :time (e.g. the daemon)
  defp execute_indexed(%{pattern: _pattern, path: _path, ignore_case: _ignore_case} = args) do
    execute_indexed(Map.put(args, :time, false))
  end

  defp execute_indexed_direct(pattern, path, ignore_case, show_time, regex) do
    {load_us, index} =
      :timer.tc(fn ->
        case Index.load(path) do
          {:ok, loaded} ->
            loaded

          {:error, :not_found} ->
            IO.puts(:stderr, "No index found, building...")
            idx = Index.build(path)
            Index.save(idx, path)
            idx
        end
      end)

    # Decompose pattern into trigram query
    query_pattern = if ignore_case, do: String.downcase(pattern), else: pattern
    query_tree = Query.decompose(query_pattern)

    # Evaluate query tree against index using mask-aware pre-filtering
    {eval_us, candidate_ids} =
      :timer.tc(fn ->
        Query.evaluate_masked(query_tree, fn trigram ->
          lookup_trigram = if ignore_case, do: String.downcase(trigram), else: trigram
          Index.lookup_with_masks(index, lookup_trigram)
        end)
      end)

    # Resolve file IDs to paths
    candidate_files = Index.resolve_files(index, candidate_ids)
    candidate_count = if candidate_ids == :all, do: index.file_count, else: MapSet.size(candidate_ids)

    # Full regex verification
    {match_us, results} = :timer.tc(fn -> Matcher.match_files(candidate_files, regex) end)

    # Output
    output = Matcher.format_results(results)
    if output != "", do: IO.puts(output)

    if show_time do
      total_us = load_us + eval_us + match_us
      IO.puts(:stderr, "")
      IO.puts(:stderr, "--- timing (pattern: #{inspect(pattern)}) ---")
      IO.puts(:stderr, "  index load:       #{fmt_us(load_us)}")
      IO.puts(:stderr, "  trigram eval:     #{fmt_us(eval_us)}  (#{candidate_count}/#{index.file_count} files candidates)")
      IO.puts(:stderr, "  regex verify:     #{fmt_us(match_us)}  (#{length(results)} matches)")
      IO.puts(:stderr, "  total (in VM):    #{fmt_us(total_us)}")
    end

    {:ok, ""}
  end

  defp execute_brute_force(%{pattern: pattern, path: path, ignore_case: ignore_case}) do
    case compile_regex(pattern, ignore_case) do
      {:ok, regex} ->
        results = Matcher.brute_force(path, regex)
        output = Matcher.format_results(results)
        {:ok, output}

      {:error, msg} ->
        {:error, 1, msg}
    end
  end

  defp compile_regex(pattern, true) do
    case Regex.compile(pattern, "i") do
      {:ok, regex} -> {:ok, regex}
      {:error, {msg, _}} -> {:error, "Invalid regex: #{msg}"}
    end
  end

  defp compile_regex(pattern, false) do
    case Regex.compile(pattern) do
      {:ok, regex} -> {:ok, regex}
      {:error, {msg, _}} -> {:error, "Invalid regex: #{msg}"}
    end
  end

  defp fmt_us(us) when us < 1_000, do: "#{us}µs"
  defp fmt_us(us) when us < 1_000_000, do: "#{Float.round(us / 1_000, 2)}ms"
  defp fmt_us(us), do: "#{Float.round(us / 1_000_000, 3)}s"
end
