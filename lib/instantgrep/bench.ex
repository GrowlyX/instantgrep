defmodule Instantgrep.Bench do
  @moduledoc """
  Benchmark CLI tool comparing instantgrep vs grep vs ripgrep.

  Usage:
      instantgrep-bench [OPTIONS] PATH

  Options:
      --patterns FILE    File with one pattern per line (default: built-in)
      --iterations N     Iterations per pattern (default: 5)
      --warmup N         Warmup iterations (default: 1)
      -h, --help         Show this help message

  Compares wall-clock execution time of:
  - instantgrep (trigram-indexed search)
  - grep -rn (standard grep)
  - rg --no-heading (ripgrep)
  """

  alias Instantgrep.{Index, Matcher, Query}

  @default_patterns [
    "defmodule",
    "import",
    "def\\s+\\w+",
    "TODO|FIXME|HACK",
    "fn.*->",
    "GenServer",
    "@spec",
    "String\\.split"
  ]

  @doc false
  @spec main([String.t()]) :: :ok
  def main(args) do
    args
    |> parse_args()
    |> execute()
  end

  defp parse_args(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          patterns: :string,
          iterations: :integer,
          warmup: :integer,
          help: :boolean
        ],
        aliases: [h: :help]
      )

    %{
      patterns_file: Keyword.get(opts, :patterns),
      iterations: Keyword.get(opts, :iterations, 5),
      warmup: Keyword.get(opts, :warmup, 1),
      help: Keyword.get(opts, :help, false),
      path: Enum.at(positional, 0, ".")
    }
  end

  defp execute(%{help: true}) do
    IO.puts(@moduledoc)
  end

  defp execute(args) do
    path = Path.expand(args.path)
    patterns = load_patterns(args.patterns_file)

    IO.puts("=" |> String.duplicate(80))
    IO.puts("instantgrep Benchmark")
    IO.puts("=" |> String.duplicate(80))
    IO.puts("Path:       #{path}")
    IO.puts("Patterns:   #{length(patterns)}")
    IO.puts("Iterations: #{args.iterations}")
    IO.puts("Warmup:     #{args.warmup}")
    IO.puts("")

    # Build instantgrep index
    IO.puts("Building instantgrep index...")
    index = Index.build(path)
    Index.stats(index)
    IO.puts("")

    # Check tool availability
    has_rg = System.find_executable("rg") != nil
    has_grep = System.find_executable("grep") != nil

    # Run benchmarks
    results =
      Enum.map(patterns, fn pattern ->
        IO.write("Benchmarking: #{pattern} ... ")

        instantgrep_times = bench_instantgrep(pattern, path, index, args.warmup, args.iterations)

        grep_times =
          if has_grep, do: bench_grep(pattern, path, args.warmup, args.iterations), else: []

        rg_times = if has_rg, do: bench_rg(pattern, path, args.warmup, args.iterations), else: []

        IO.puts("done")

        %{
          pattern: pattern,
          instantgrep: instantgrep_times,
          grep: grep_times,
          rg: rg_times
        }
      end)

    # Print results table
    IO.puts("")
    print_results(results, has_grep, has_rg)
  end

  # --- Benchmark Runners ---

  defp bench_instantgrep(pattern, _path, index, warmup, iterations) do
    regex = Regex.compile!(pattern)
    query_tree = Query.decompose(pattern)

    run_fn = fn ->
      candidate_ids =
        Query.evaluate_masked(query_tree, fn trigram -> Index.lookup_with_masks(index, trigram) end)

      candidate_files = Index.resolve_files(index, candidate_ids)
      results = Matcher.match_files(candidate_files, regex)
      length(results)
    end

    # Warmup
    for _ <- 1..warmup, do: run_fn.()

    # Measure
    for _ <- 1..iterations do
      {time_us, _result} = :timer.tc(run_fn)
      time_us
    end
  end

  defp bench_grep(pattern, path, warmup, iterations) do
    cmd = "grep -rn --include='*' '#{escape_shell(pattern)}' '#{path}' 2>/dev/null | wc -l"

    # Warmup
    for _ <- 1..warmup, do: :os.cmd(String.to_charlist(cmd))

    # Measure
    for _ <- 1..iterations do
      {time_us, _} = :timer.tc(fn -> :os.cmd(String.to_charlist(cmd)) end)
      time_us
    end
  end

  defp bench_rg(pattern, path, warmup, iterations) do
    cmd = "rg --no-heading -c '#{escape_shell(pattern)}' '#{path}' 2>/dev/null | wc -l"

    # Warmup
    for _ <- 1..warmup, do: :os.cmd(String.to_charlist(cmd))

    # Measure
    for _ <- 1..iterations do
      {time_us, _} = :timer.tc(fn -> :os.cmd(String.to_charlist(cmd)) end)
      time_us
    end
  end

  # --- Results ---

  defp print_results(results, has_grep, has_rg) do
    header_parts = ["Pattern", "instantgrep (median)"]

    header_parts =
      if has_grep, do: header_parts ++ ["grep (median)", "vs grep"], else: header_parts

    header_parts = if has_rg, do: header_parts ++ ["rg (median)", "vs rg"], else: header_parts

    col_widths = [30, 15, 15, 10, 15, 10]

    # Header
    IO.puts(format_row(header_parts, col_widths))
    IO.puts(String.duplicate("-", 95))

    # Rows
    Enum.each(results, fn result ->
      instantgrep_median = median(result.instantgrep)

      row = [
        truncate(result.pattern, 28),
        format_time(instantgrep_median)
      ]

      row =
        if has_grep do
          grep_median = median(result.grep)

          speedup =
            if instantgrep_median > 0,
              do: Float.round(grep_median / instantgrep_median, 1),
              else: 0.0

          row ++ [format_time(grep_median), "#{speedup}x"]
        else
          row
        end

      row =
        if has_rg do
          rg_median = median(result.rg)

          speedup =
            if instantgrep_median > 0,
              do: Float.round(rg_median / instantgrep_median, 1),
              else: 0.0

          row ++ [format_time(rg_median), "#{speedup}x"]
        else
          row
        end

      IO.puts(format_row(row, col_widths))
    end)

    IO.puts("")
    IO.puts("Note: speedup > 1.0 means instantgrep is faster")
  end

  defp format_row(cols, widths) do
    cols
    |> Enum.zip(widths)
    |> Enum.map(fn {col, width} -> String.pad_trailing(to_string(col), width) end)
    |> Enum.join("  ")
  end

  defp truncate(str, max_len) do
    if String.length(str) > max_len do
      String.slice(str, 0, max_len - 2) <> ".."
    else
      str
    end
  end

  # --- Helpers ---

  defp load_patterns(nil), do: @default_patterns

  defp load_patterns(file) do
    file
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&(String.starts_with?(&1, "#") or String.trim(&1) == ""))
  end

  defp median([]), do: 0

  defp median(list) do
    sorted = Enum.sort(list)
    len = length(sorted)
    mid = div(len, 2)

    if rem(len, 2) == 0 do
      div(Enum.at(sorted, mid - 1) + Enum.at(sorted, mid), 2)
    else
      Enum.at(sorted, mid)
    end
  end

  defp format_time(us) when us < 1_000, do: "#{us}µs"
  defp format_time(us) when us < 1_000_000, do: "#{Float.round(us / 1_000, 1)}ms"
  defp format_time(us), do: "#{Float.round(us / 1_000_000, 2)}s"

  defp escape_shell(str) do
    String.replace(str, "'", "'\\''")
  end
end
