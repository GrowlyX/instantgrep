defmodule Instantgrep.Daemon do
  @moduledoc """
  Unix-socket search daemon.

  Loads the trigram index once and serves search requests over a Unix domain
  socket, eliminating the ~4s cold-start deserialization cost per query.

  ## Starting the daemon

      instantgrep --daemon /path/to/project

  ## Searching via the daemon (automatic)

  When a daemon is running for a given path, `instantgrep` automatically
  connects to it instead of loading the index from disk:

      instantgrep "pattern" /path/to/project        # uses daemon if running
      instantgrep --stop /path/to/project            # stop running daemon

  ## Protocol (line-oriented, newline-terminated)

    Client → Server: `<pattern>\\t<ignore_case>\\n`  (ignore_case: "0" or "1")
    Server → Client: `<file>:<line>:<content>\\n`    (one line per match)
                     `\\DONE\\t<ms>\\t<candidates>\\t<matches>\\n`  (end of results)
                     `\\ERROR\\t<message>\\n`                        (on failure)
  """

  require Logger

  alias Instantgrep.{Index, Query}

  @sock_name "daemon.sock"
  @pid_name "daemon.pid"

  # ---- Public API ----

  @doc "Absolute path to the Unix socket for a given project directory."
  @spec socket_path(String.t()) :: String.t()
  def socket_path(base_dir), do: Path.join([base_dir, ".instantgrep", @sock_name])

  @doc "Returns true if a daemon is listening on the socket for this path."
  @spec running?(String.t()) :: boolean()
  def running?(base_dir) do
    sock = socket_path(base_dir)

    case :gen_tcp.connect({:local, sock}, 0, [:binary, packet: :line, active: false], 500) do
      {:ok, s} ->
        :gen_tcp.close(s)
        true

      {:error, _} ->
        false
    end
  end

  @doc """
  Start the daemon synchronously (blocks forever).

  Loads or builds the index for `base_dir`, binds the Unix socket, and serves
  search requests until the process is killed or `--stop` is sent.
  """
  @spec start(String.t()) :: no_return()
  def start(base_dir) do
    sock_path = socket_path(base_dir)
    pid_path = Path.join([base_dir, ".instantgrep", @pid_name])

    index =
      case Index.load(base_dir) do
        {:ok, idx} ->
          IO.puts(:stderr, "Index loaded from disk.")
          idx

        {:error, :not_found} ->
          IO.puts(:stderr, "No index found, building...")
          idx = Index.build(base_dir)
          Index.save(idx, base_dir)
          idx
      end

    Index.stats(index)

    # Pre-load all indexed file content into ETS so searches are pure RAM ops.
    IO.puts(:stderr, "Pre-loading file content cache...")
    t_cache = System.monotonic_time(:millisecond)
    content_cache = build_content_cache(index)
    cached = :ets.info(content_cache, :size)
    elapsed_cache = System.monotonic_time(:millisecond) - t_cache
    IO.puts(:stderr, "  Cached #{cached} files in #{elapsed_cache}ms")

    # Remove a stale socket file from a previous run
    File.rm(sock_path)

    {:ok, server} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :line,
        active: false,
        reuseaddr: true,
        ifaddr: {:local, sock_path}
      ])

    # Write our PID so --stop can send SIGTERM
    File.write!(pid_path, "#{System.pid()}\n")

    IO.puts("instantgrep daemon ready  path=#{base_dir}")
    IO.puts("  socket : #{sock_path}")
    IO.puts("  pid    : #{System.pid()}")
    IO.puts("  stop   : instantgrep --stop #{base_dir}")

    # Ignore SIGHUP so daemon survives terminal close; SIGTERM still stops it cleanly.
    :os.set_signal(:sighup, :ignore)

    accept_loop(server, index, content_cache)
  end

  @doc """
  Stop a running daemon by sending SIGTERM to its PID file.
  """
  @spec stop(String.t()) :: :ok | {:error, String.t()}
  def stop(base_dir) do
    pid_path = Path.join([base_dir, ".instantgrep", @pid_name])
    sock_path = socket_path(base_dir)

    case File.read(pid_path) do
      {:ok, contents} ->
        pid = String.trim(contents)
        System.cmd("kill", [pid], stderr_to_stdout: true)
        File.rm(pid_path)
        File.rm(sock_path)
        IO.puts("Daemon #{pid} stopped.")
        :ok

      {:error, _} ->
        {:error, "No daemon PID file found at #{pid_path}"}
    end
  end

  @doc """
  Send a search request to the running daemon. Returns results immediately.

  Returns `{:ok, lines, stats}` or `{:error, reason}`.
  """
  @spec search(String.t(), String.t(), boolean()) ::
          {:ok, [String.t()], map()} | {:error, term()}
  def search(base_dir, pattern, ignore_case) do
    sock_path = socket_path(base_dir)
    ic = if ignore_case, do: "1", else: "0"

    case :gen_tcp.connect({:local, sock_path}, 0, [:binary, packet: :line, active: false], 2_000) do
      {:ok, socket} ->
        :gen_tcp.send(socket, "#{pattern}\t#{ic}\n")
        result = collect_results(socket, [])
        :gen_tcp.close(socket)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---- Private: Accept Loop ----

  defp accept_loop(server, index, content_cache) do
    case :gen_tcp.accept(server) do
      {:ok, client} ->
        # Each search runs in its own Task — ETS read_concurrency handles parallel queries
        Task.start(fn -> handle_client(client, index, content_cache) end)
        accept_loop(server, index, content_cache)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("accept error: #{inspect(reason)}")
        accept_loop(server, index, content_cache)
    end
  end

  # ---- Private: Client Handler ----

  defp handle_client(socket, index, content_cache) do
    case :gen_tcp.recv(socket, 0, 10_000) do
      {:ok, line} ->
        line = String.trim_trailing(line, "\n")

        case String.split(line, "\t", parts: 2) do
          [pattern, ic_flag] ->
            run_search(socket, index, content_cache, pattern, ic_flag == "1")

          _ ->
            send_line(socket, "\\ERROR\tbad request: expected pattern<TAB>0|1")
        end

      {:error, _} ->
        :ok
    end

    :gen_tcp.close(socket)
  end

  defp run_search(socket, index, content_cache, pattern, ignore_case) do
    t0 = System.monotonic_time(:millisecond)

    re_opts = if ignore_case, do: [:caseless], else: []

    case :re.compile(pattern, re_opts) do
      {:error, {msg, _}} ->
        send_line(socket, "\\ERROR\tinvalid regex: #{msg}")

      {:ok, compiled_re} ->
        query_pattern = if ignore_case, do: String.downcase(pattern), else: pattern
        query_tree = Query.decompose(query_pattern)

        candidate_ids =
          Query.evaluate_masked(query_tree, fn trigram ->
            t = if ignore_case, do: String.downcase(trigram), else: trigram
            Index.lookup_with_masks(index, t)
          end)

        candidate_count =
          if candidate_ids == :all, do: index.file_count, else: MapSet.size(candidate_ids)

        # Resolve to {file_id, path} pairs so we can look up cached content by id
        candidate_entries =
          case candidate_ids do
            :all ->
              :ets.tab2list(index.files_table)

            ids ->
              ids
              |> MapSet.to_list()
              |> Enum.flat_map(fn id ->
                case :ets.lookup(index.files_table, id) do
                  [{^id, path}] -> [{id, path}]
                  [] -> []
                end
              end)
          end

        # Determine search strategy once, outside the per-file tasks:
        #   :literal       — single literal (no metacharacters)
        #   {:alts, list}  — A|B|C alternation of literals
        #   :regex         — general PCRE
        smode = search_mode(pattern, ignore_case)

        results =
          candidate_entries
          |> Task.async_stream(
            fn {file_id, path} ->
              case :ets.lookup(content_cache, file_id) do
                [{^file_id, content, newlines}] ->
                  dispatch_match(content, path, smode, pattern, compiled_re, newlines)

                [] ->
                  case File.read(path) do
                    {:ok, c} ->
                      nl = build_newline_index(c)
                      dispatch_match(c, path, smode, pattern, compiled_re, nl)

                    _ ->
                      []
                  end
              end
            end,
            max_concurrency: System.schedulers_online() * 2,
            ordered: false,
            timeout: 10_000
          )
          |> Enum.flat_map(fn
            {:ok, r} -> r
            _ -> []
          end)
          |> Enum.sort_by(fn %{file: f, line: l} -> {f, l} end)

        elapsed = System.monotonic_time(:millisecond) - t0
        match_count = length(results)

        Enum.each(results, fn %{file: f, line: l, content: c} ->
          send_line(socket, "#{f}:#{l}:#{c}")
        end)

        send_line(socket, "\\DONE\t#{elapsed}\t#{candidate_count}\t#{match_count}")
    end
  end

  # ---- Private: Content Cache ----

  # Pre-read every indexed file into ETS, keyed by file_id.
  # Also pre-computes the newline offset tuple so searches never rebuild it.
  # ETS record: {file_id, content_binary, newlines_tuple}
  defp build_content_cache(index) do
    table =
      :ets.new(:ig_content_cache, [
        :set,
        :public,
        read_concurrency: true
      ])

    :ets.tab2list(index.files_table)
    |> Task.async_stream(
      fn {id, path} ->
        case File.read(path) do
          {:ok, content} ->
            newlines = build_newline_index(content)
            {id, content, newlines}

          {:error, _} ->
            nil
        end
      end,
      max_concurrency: System.schedulers_online() * 2,
      ordered: false,
      timeout: 30_000
    )
    |> Enum.each(fn
      {:ok, {id, content, newlines}} -> :ets.insert(table, {id, content, newlines})
      _ -> :ok
    end)

    table
  end

  # Classify the search pattern to choose the fastest matching strategy.
  # ignore_case always falls back to PCRE.
  @re_metacharacters [".", "*", "+", "?", "(", ")", "[", "]", "{", "}", "^", "$", "|", "\\"]
  @re_meta_no_pipe   [".", "*", "+", "?", "(", ")", "[", "]", "{", "}", "^", "$", "\\"]

  defp search_mode(_pattern, true), do: :regex
  defp search_mode(pattern, false) do
    cond do
      not String.contains?(pattern, @re_metacharacters) ->
        :literal

      # Pure alternation of literals: "A|B|C"  (no other metacharacters)
      (alts = String.split(pattern, "|");
       Enum.all?(alts, fn a -> not String.contains?(a, @re_meta_no_pipe) end)) ->
        {:alts, alts}

      true ->
        :regex
    end
  end

  defp dispatch_match(content, path, :literal, pattern, _re, newlines),
    do: match_literal_fast(content, path, pattern, newlines)

  defp dispatch_match(content, path, {:alts, alts}, _pattern, _re, newlines),
    do: match_literal_fast(content, path, alts, newlines)

  defp dispatch_match(content, path, :regex, _pattern, compiled_re, newlines),
    do: match_content_fast(content, path, compiled_re, newlines)

  defp match_literal_fast(content, path, pattern, newlines) do
    case :binary.matches(content, pattern) do
      [] -> []
      # :binary.matches returns [{offset, len}] directly
      positions -> extract_lines(positions, content, path, newlines)
    end
  end

  # PCRE path for patterns that contain regex metacharacters.
  # Uses pre-computed newline index (no rebuild cost per search).
  defp match_content_fast(content, path, compiled_re, newlines) do
    case :re.run(content, compiled_re, [:global, capture: :first]) do
      # :re.run returns [[{offset, len}]] (each match is a list of captures)
      {:match, all_matches} -> extract_lines(Enum.map(all_matches, &hd/1), content, path, newlines)
      :nomatch -> []
    end
  end

  # Shared line-extraction logic: given a list of {offset, len} positions,
  # binary-search the newline index to find each match's line and content.
  # De-duplicates multiple matches on the same line (grep-compatible).
  defp extract_lines(positions, content, path, newlines) do
    n_newlines = tuple_size(newlines)
    content_size = byte_size(content)

    {results, _last} =
      Enum.reduce(positions, {[], -1}, fn {offset, _len}, {acc, last_line_idx} ->
        line_idx = bisect(newlines, n_newlines, offset)

        if line_idx == last_line_idx do
          {acc, last_line_idx}
        else
          line_start = if line_idx == 0, do: 0, else: elem(newlines, line_idx - 1) + 1

          line_end =
            if line_idx < n_newlines,
              do: elem(newlines, line_idx),
              else: content_size

          line = binary_part(content, line_start, max(0, line_end - line_start))
          {[%{file: path, line: line_idx + 1, content: line} | acc], line_idx}
        end
      end)

    Enum.reverse(results)
  end

  # Build a sorted tuple of byte offsets of every '\n' in the binary.
  # One O(n) pass; result is used for O(log n) binary search per match.
  defp build_newline_index(content), do: do_newlines(content, 0, []) |> :lists.reverse() |> List.to_tuple()

  defp do_newlines(<<>>, _pos, acc), do: acc
  defp do_newlines(<<10, rest::binary>>, pos, acc), do: do_newlines(rest, pos + 1, [pos | acc])
  defp do_newlines(<<_, rest::binary>>, pos, acc), do: do_newlines(rest, pos + 1, acc)

  # Binary search: return the index of the newline that "contains" byte offset.
  # Returns the 0-based line index (i.e. how many newlines precede this offset).
  defp bisect(newlines, n, offset), do: bisect(newlines, 0, n, offset)
  defp bisect(_newlines, lo, hi, _offset) when lo >= hi, do: lo
  defp bisect(newlines, lo, hi, offset) do
    mid = div(lo + hi, 2)
    if elem(newlines, mid) <= offset,
      do: bisect(newlines, mid + 1, hi, offset),
      else: bisect(newlines, lo, mid, offset)
  end

  defp send_line(socket, msg), do: :gen_tcp.send(socket, msg <> "\n")

  # ---- Private: Result Collection ----

  defp collect_results(socket, acc) do
    case :gen_tcp.recv(socket, 0, 30_000) do
      {:ok, "\\DONE\t" <> rest} ->
        case String.split(String.trim(rest), "\t") do
          [ms, cands, matches] ->
            {:ok, Enum.reverse(acc),
             %{
               elapsed_ms: String.to_integer(ms),
               candidates: String.to_integer(cands),
               matches: String.to_integer(matches)
             }}

          _ ->
            {:ok, Enum.reverse(acc), %{elapsed_ms: 0, candidates: 0, matches: 0}}
        end

      {:ok, "\\ERROR\t" <> msg} ->
        {:error, String.trim(msg)}

      {:ok, line} ->
        collect_results(socket, [String.trim_trailing(line, "\n") | acc])

      {:error, reason} ->
        {:error, reason}
    end
  end
end
