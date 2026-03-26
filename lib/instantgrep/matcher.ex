defmodule Instantgrep.Matcher do
  @moduledoc """
  Parallel regex matching on candidate files.

  Given a list of file paths and a compiled regex, scans each file
  line-by-line and returns matching results in grep-compatible format.
  """

  @type match_result :: %{
          file: String.t(),
          line: pos_integer(),
          content: String.t()
        }

  @doc """
  Match a regex against a list of candidate files in parallel.

  Returns a list of `%{file: path, line: number, content: text}` maps,
  sorted by file path and line number.
  """
  @spec match_files([String.t()], Regex.t()) :: [match_result()]
  def match_files(file_paths, regex) do
    file_paths
    |> Task.async_stream(
      fn path -> match_single_file(path, regex) end,
      max_concurrency: System.schedulers_online() * 2,
      ordered: false,
      timeout: 10_000
    )
    |> Enum.flat_map(fn
      {:ok, results} -> results
      {:exit, _reason} -> []
    end)
    |> Enum.sort_by(fn %{file: f, line: l} -> {f, l} end)
  end

  @doc """
  Brute-force scan: match regex against all files in a directory.

  This is the fallback "grep mode" — no index used.
  """
  @spec brute_force(String.t(), Regex.t()) :: [match_result()]
  def brute_force(path, regex) do
    files =
      path
      |> Instantgrep.Scanner.scan()
      |> Enum.map(fn {_id, file_path} -> file_path end)

    match_files(files, regex)
  end

  @doc """
  Format match results as grep-compatible output lines.
  """
  @spec format_results([match_result()]) :: String.t()
  def format_results(results) do
    results
    |> Enum.map(fn %{file: f, line: l, content: c} ->
      "#{f}:#{l}:#{c}"
    end)
    |> Enum.join("\n")
  end

  # --- Private ---

  defp match_single_file(path, regex) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> :binary.split("\n", [:global])
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, line_num} ->
          if Regex.match?(regex, line) do
            [%{file: path, line: line_num, content: line}]
          else
            []
          end
        end)

      {:error, _} ->
        []
    end
  end
end
