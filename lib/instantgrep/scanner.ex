defmodule Instantgrep.Scanner do
  @moduledoc """
  Recursive file scanner with ignore-pattern support.

  Walks a directory tree collecting text files suitable for indexing.
  Skips binary files, VCS directories, build artifacts, and paths
  matching `.gitignore` patterns.
  """

  @default_ignores [
    ~r{/\.git(/|$)},
    ~r{/node_modules(/|$)},
    ~r{/_build(/|$)},
    ~r{/deps(/|$)},
    ~r{/\.instantgrep(/|$)},
    ~r{/\.elixir_ls(/|$)},
    ~r{/\.idea(/|$)},
    ~r{/\.vscode(/|$)},
    ~r{/target(/|$)},
    ~r{/vendor(/|$)}
  ]

  @binary_extensions ~w(.png .jpg .jpeg .gif .bmp .ico .svg .woff .woff2 .ttf .eot
    .mp3 .mp4 .avi .mov .pdf .zip .tar .gz .bz2 .xz .7z .rar
    .exe .dll .so .dylib .o .a .beam .class .jar .war .pyc .pyo
    .DS_Store .lock)

  @max_file_size 1_048_576

  @doc """
  Scan a directory and return a list of `{file_id, path}` tuples.

  Options:
  - `:max_file_size` — skip files larger than this (default: 1MB)
  """
  @spec scan(String.t(), keyword()) :: [{non_neg_integer(), String.t()}]
  def scan(path, opts \\ []) do
    max_size = Keyword.get(opts, :max_file_size, @max_file_size)
    gitignore_patterns = load_gitignore(path)

    path
    |> Path.expand()
    |> do_scan_parallel(max_size, gitignore_patterns)
    |> Enum.with_index()
    |> Enum.map(fn {file_path, idx} -> {idx, file_path} end)
  end

  # --- Private ---

  defp do_scan(path, max_size, gitignore_patterns) do
    cond do
      File.regular?(path) ->
        if indexable_file?(path, max_size, gitignore_patterns), do: [path], else: []

      File.dir?(path) ->
        if ignored_dir?(path) do
          []
        else
          case File.ls(path) do
            {:error, _} ->
              []

            {:ok, entries} ->
              entries
              |> Enum.flat_map(fn entry ->
                do_scan(Path.join(path, entry), max_size, gitignore_patterns)
              end)
              # No sort here — do_scan_parallel sorts the full combined list once at the top level.
          end
        end

      true ->
        []
    end
  end

  # Parallel top-level scan: dispatches each immediate child of the root in
  # a separate Task; recursion within each task is sequential to avoid
  # nested async_stream timeouts on deep directory trees.
  defp do_scan_parallel(path, max_size, gitignore_patterns) do
    case File.ls(path) do
      {:error, _} ->
        []

      {:ok, entries} ->
        entries
        |> Task.async_stream(
          fn entry ->
            do_scan(Path.join(path, entry), max_size, gitignore_patterns)
          end,
          max_concurrency: System.schedulers_online(),
          ordered: false,
          timeout: :infinity
        )
        |> Enum.flat_map(fn
          {:ok, results} -> results
          {:exit, _} -> []
        end)
        |> Enum.sort()
    end
  end

  defp indexable_file?(path, max_size, gitignore_patterns) do
    ext = Path.extname(path)
    basename = Path.basename(path)

    cond do
      ext in @binary_extensions -> false
      String.starts_with?(basename, ".") and ext == "" -> false
      gitignore_match?(path, gitignore_patterns) -> false
      true -> file_size_ok?(path, max_size)
    end
  end

  defp file_size_ok?(path, max_size) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size <= max_size and size > 0
      _ -> false
    end
  end

  defp ignored_dir?(path) do
    Enum.any?(@default_ignores, &Regex.match?(&1, path))
  end

  defp gitignore_match?(_path, []), do: false

  defp gitignore_match?(path, patterns) do
    Enum.any?(patterns, &Regex.match?(&1, path))
  end

  defp load_gitignore(path) do
    dir = if File.dir?(path), do: path, else: Path.dirname(path)
    gitignore_file = Path.join(dir, ".gitignore")

    if File.regular?(gitignore_file) do
      gitignore_file
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reject(&(String.starts_with?(&1, "#") or String.trim(&1) == ""))
      |> Enum.flat_map(&gitignore_to_regex/1)
    else
      []
    end
  end

  defp gitignore_to_regex(pattern) do
    pattern = String.trim(pattern)
    # Convert simple gitignore glob to regex
    regex_str =
      pattern
      |> String.replace(".", "\\.")
      |> String.replace("**/", "(.*/)?")
      |> String.replace("*", "[^/]*")
      |> String.replace("?", "[^/]")

    case Regex.compile(regex_str) do
      {:ok, regex} -> [regex]
      _ -> []
    end
  end
end
