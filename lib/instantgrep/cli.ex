defmodule Instantgrep.CLI do
  @moduledoc """
  Main CLI entry point for the instantgrep escript.

  Usage:
      instantgrep [OPTIONS] PATTERN [PATH]

  Options:
      --build          Build/rebuild index only (no search)
      --no-index       Skip index, brute-force scan (like grep)
      -i, --ignore-case   Case-insensitive matching
      --stats          Show index statistics
      -h, --help       Show this help message

  Examples:
      instantgrep "defmodule" lib/
      instantgrep --build .
      instantgrep -i "todo|fixme" src/
      instantgrep --no-index "pattern" .
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
          no_index: :boolean,
          ignore_case: :boolean,
          stats: :boolean,
          daemon: :boolean,
          help: :boolean
        ],
        aliases: [i: :ignore_case, h: :help]
      )

    %{
      build: Keyword.get(opts, :build, false),
      no_index: Keyword.get(opts, :no_index, false),
      ignore_case: Keyword.get(opts, :ignore_case, false),
      stats: Keyword.get(opts, :stats, false),
      daemon: Keyword.get(opts, :daemon, false),
      help: Keyword.get(opts, :help, false),
      pattern: Enum.at(positional, 0),
      path: Enum.at(positional, 1, ".")
    }
  end

  # --- Command Execution ---

  @doc false
  def execute(%{help: true}) do
    {:ok, @moduledoc}
  end

  def execute(%{build: true, path: path}) do
    index = Index.build(path)
    Index.save(index, path)
    stats = Index.stats(index)
    output = """
    Building index for #{path}...
    Index saved to #{Path.join(path, ".instantgrep")}/
    #{stats}
    """ |> String.trim_trailing()
    {:ok, output}
  end

  def execute(%{stats: true, path: path}) do
    case Index.load(path) do
      {:ok, index} -> {:ok, Index.stats(index)}
      {:error, :not_found} -> {:error, 1, "No index found. Run: instantgrep --build #{path}"}
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

  defp execute_indexed(%{pattern: pattern, path: path, ignore_case: ignore_case}) do
    case compile_regex(pattern, ignore_case) do
      {:ok, regex} ->
        # Try loading existing index, or build one
        {index, build_msg} =
          case Index.load(path) do
            {:ok, loaded} ->
              {loaded, ""}

            {:error, :not_found} ->
              idx = Index.build(path)
              Index.save(idx, path)
              {idx, "No index found, building...\n"}
          end

        # Decompose pattern into trigram query
        query_pattern = if ignore_case, do: String.downcase(pattern), else: pattern
        query_tree = Query.decompose(query_pattern)

        # Evaluate query tree against index
        candidate_ids =
          Query.evaluate(query_tree, fn trigram ->
            lookup_trigram = if ignore_case, do: String.downcase(trigram), else: trigram
            Index.lookup(index, lookup_trigram)
          end)

        # Resolve file IDs to paths
        candidate_files = Index.resolve_files(index, candidate_ids)

        # Full regex verification
        results = Matcher.match_files(candidate_files, regex)

        # Output
        output = Matcher.format_results(results)
        full_output = if build_msg != "", do: build_msg <> output, else: output

        {:ok, full_output}

      {:error, msg} ->
        {:error, 1, msg}
    end
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
end
