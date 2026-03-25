defmodule Instantgrep.CLI do
  @moduledoc """
  Main CLI entry point for the instantgrep escript.

  Usage:
      instantgrep [OPTIONS] PATTERN [PATH]

  Options:
      --build          Build/rebuild index only (no search)
      --daemon         Start persistent search daemon (loads index once, serves forever)
      --stop           Stop a running daemon
      --no-index       Skip index, brute-force scan (like grep)
      -i, --ignore-case   Case-insensitive matching
      --stats          Show index statistics
      --time           Print per-phase timing to stderr
      -h, --help       Show this help message

  Examples:
      instantgrep --build .                # build index
      instantgrep --daemon .               # start daemon (background with: & or systemd)
      instantgrep "pattern" .              # search (uses daemon if running, else direct)
      instantgrep --stop .                 # stop running daemon
      instantgrep -i "todo|fixme" src/
      instantgrep --no-index "pattern" .   # brute-force, no index
      instantgrep --time "pattern" .       # show per-phase timing
  """

  alias Instantgrep.{Daemon, Index, Matcher, Query}

  @doc false
  @spec main([String.t()]) :: :ok
  def main(args) do
    args
    |> parse_args()
    |> execute()
  end

  # --- Argument Parsing ---

  defp parse_args(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          build: :boolean,
          daemon: :boolean,
          stop: :boolean,
          no_index: :boolean,
          ignore_case: :boolean,
          stats: :boolean,
          time: :boolean,
          help: :boolean
        ],
        aliases: [i: :ignore_case, h: :help]
      )

    build  = Keyword.get(opts, :build,  false)
    daemon = Keyword.get(opts, :daemon, false)
    stop   = Keyword.get(opts, :stop,   false)
    stats  = Keyword.get(opts, :stats,  false)

    # For --build / --stats / --daemon / --stop, positional[0] is the directory.
    # For search, positional[0] is the pattern and positional[1] is the path.
    {pattern, path} =
      if build or stats or daemon or stop do
        {nil, Enum.at(positional, 0, ".")}
      else
        {Enum.at(positional, 0), Enum.at(positional, 1, ".")}
      end

    %{
      build: build,
      daemon: daemon,
      stop: stop,
      no_index: Keyword.get(opts, :no_index, false),
      ignore_case: Keyword.get(opts, :ignore_case, false),
      stats: stats,
      time: Keyword.get(opts, :time, false),
      help: Keyword.get(opts, :help, false),
      pattern: pattern,
      path: path
    }
  end

  # --- Command Execution ---

  defp execute(%{help: true}) do
    IO.puts(@moduledoc)
  end

  defp execute(%{daemon: true, path: path}) do
    Daemon.start(path)
  end

  defp execute(%{stop: true, path: path}) do
    case Daemon.stop(path) do
      :ok -> :ok
      {:error, msg} -> IO.puts(:stderr, "Error: #{msg}")
    end
  end

  defp execute(%{build: true, path: path}) do
    IO.puts("Building index for #{path}...")
    index = Index.build(path)
    Index.save(index, path)
    Index.stats(index)
    IO.puts("Index saved to #{Path.join(path, ".instantgrep")}/")
  end

  defp execute(%{stats: true, path: path}) do
    case Index.load(path) do
      {:ok, index} -> Index.stats(index)
      {:error, :not_found} -> IO.puts(:stderr, "No index found. Run: instantgrep --build #{path}")
    end
  end

  defp execute(%{pattern: nil}) do
    IO.puts(:stderr, "Error: no pattern specified. Run: instantgrep --help")
    System.halt(1)
  end

  defp execute(%{no_index: true} = args) do
    execute_brute_force(args)
  end

  defp execute(args) do
    execute_indexed(args)
  end

  defp execute_indexed(%{pattern: pattern, path: path, ignore_case: ignore_case, time: show_time}) do
    # Try the daemon first — avoids the ~4s cold index load.
    # Falls back to direct index load if no daemon is running.
    case Daemon.search(path, pattern, ignore_case) do
      {:ok, lines, stats} ->
        Enum.each(lines, &IO.puts/1)

        if show_time do
          IO.puts(:stderr, "")
          IO.puts(:stderr, "--- timing via daemon (pattern: #{inspect(pattern)}) ---")
          IO.puts(:stderr, "  index load:    0ms  (index resident in daemon)")
          IO.puts(:stderr, "  search:        #{stats.elapsed_ms}ms  (#{stats.candidates} candidates, #{stats.matches} matches)")
        end

      {:error, _} ->
        # No daemon — load index directly
        execute_indexed_direct(pattern, path, ignore_case, show_time)
    end
  end

  defp execute_indexed_direct(pattern, path, ignore_case, show_time) do
    regex = compile_regex(pattern, ignore_case)

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
  end

  defp execute_brute_force(%{pattern: pattern, path: path, ignore_case: ignore_case}) do
    regex = compile_regex(pattern, ignore_case)
    results = Matcher.brute_force(path, regex)
    output = Matcher.format_results(results)

    if output != "" do
      IO.puts(output)
    end
  end

  defp compile_regex(pattern, true) do
    case Regex.compile(pattern, "i") do
      {:ok, regex} -> regex
      {:error, {msg, _}} -> error_exit("Invalid regex: #{msg}")
    end
  end

  defp compile_regex(pattern, false) do
    case Regex.compile(pattern) do
      {:ok, regex} -> regex
      {:error, {msg, _}} -> error_exit("Invalid regex: #{msg}")
    end
  end

  defp fmt_us(us) when us < 1_000, do: "#{us}µs"
  defp fmt_us(us) when us < 1_000_000, do: "#{Float.round(us / 1_000, 2)}ms"
  defp fmt_us(us), do: "#{Float.round(us / 1_000_000, 3)}s"

  defp error_exit(message) do
    IO.puts(:stderr, "Error: #{message}")
    System.halt(1)
  end
end
