defmodule Instantgrep.Native do
  @moduledoc """
  PCRE2-JIT NIF wrapper for fast content scanning.

  Falls back transparently to Erlang's `:re` when the NIF is unavailable
  (e.g. not yet built, or running on a platform without JIT support).

  ## Building the NIF

      make all           # builds priv/instantgrep_native.so
      make clean         # removes the .so

  Requires `libpcre2-dev` (Debian/Ubuntu) or `pcre2` (Homebrew).

  ## Availability check

      Instantgrep.Native.nif_available?()   # => true | false

  ## Usage

      {:ok, compiled} = Instantgrep.Native.compile_pattern("foo.*bar", 0)
      positions = Instantgrep.Native.scan_content(compiled, file_content)
      # [{offset, len}, ...]
  """

  @on_load :load_nif

  @doc false
  def load_nif do
    case find_nif_path() do
      nil ->
        :ok

      path ->
        result = :erlang.load_nif(String.to_charlist(path), 0)
        case result do
          :ok                     -> :ok
          {:error, {:upgrade, _}} -> :ok   # already loaded (hot-reload)
          {:error, {:reload, _}}  -> :ok   # already loaded
          {:error, reason}        ->
            :logger.warning(~c"instantgrep NIF load failed: ~p (path: ~s)", [reason, path])
            :ok
        end
    end
  end

  @doc "Returns true if the PCRE2-JIT NIF was successfully loaded."
  @spec nif_available?() :: boolean()
  def nif_available? do
    try do
      compile_pattern_nif("a", 0)
      true
    rescue
      ErlangError -> false
    end
  end

  @doc """
  Compile a regex pattern. Returns `{:ok, compiled}` or `{:error, reason}`.

  `compiled` is opaque — pass it unchanged to `scan_content/2`.

  `flags` is a bitmask:
  - bit 0 (0x1) — case-insensitive (PCRE2_CASELESS)
  """
  @spec compile_pattern(binary(), non_neg_integer()) :: {:ok, term()} | {:error, term()}
  def compile_pattern(pattern, flags) do
    try do
      case compile_pattern_nif(pattern, flags) do
        {:ok, resource} -> {:ok, {:nif, resource}}
        {:error, msg}   -> {:error, {msg, 0}}
      end
    rescue
      ErlangError -> fallback_compile(pattern, flags)
    end
  end

  @doc """
  Scan `content` against a compiled pattern (from `compile_pattern/2`).

  Returns `[{offset, length}]` in ascending offset order — same shape as
  `:binary.matches` and `:re.run/3` with `[:global, capture: :first]`.

  The NIF path runs on a dirty CPU scheduler, so it never blocks BEAM.
  """
  @spec scan_content(term(), binary()) :: [{non_neg_integer(), non_neg_integer()}]
  def scan_content({:nif, resource}, content) do
    scan_content_nif(resource, content)
  end

  def scan_content({:re, compiled}, content) do
    case :re.run(content, compiled, [:global, capture: :first]) do
      {:match, all_matches} -> Enum.map(all_matches, &hd/1)
      :nomatch              -> []
    end
  end

  # ---- Private helpers ----

  @doc """
  Extract trigrams from `content` for indexing.

  Returns `[{trigram_int, next_mask, loc_mask}]` in arbitrary order, where
  `trigram_int` is the 24-bit integer `byte0<<16 | byte1<<8 | byte2`.

  Uses the C NIF (open-addressing hash table, single tight loop) when
  available, which is 5–20x faster than the pure-Elixir path for large files.
  Falls back transparently to `Trigram.extract_with_masks/1` when the NIF is
  not loaded.
  """
  @spec extract_trigrams(binary()) :: [{non_neg_integer(), byte(), byte()}]
  def extract_trigrams(content) when is_binary(content) do
    try do
      extract_trigrams_nif(content)
    rescue
      ErlangError ->
        Instantgrep.Trigram.extract_with_masks(content)
        |> Enum.map(fn {k, {nm, lm}} -> {k, nm, lm} end)
    end
  end

  # ---- Private helpers ----

  defp fallback_compile(pattern, flags) do
    re_opts = if :erlang.band(flags, 1) != 0, do: [:caseless], else: []
    case :re.compile(pattern, re_opts) do
      {:ok, compiled}  -> {:ok, {:re, compiled}}
      {:error, _} = e  -> e
    end
  end

  defp find_nif_path do
    ext = ".so"

    # :code.priv_dir(:instantgrep) resolves the priv/ directory of the loaded app,
    # which works correctly both under Mix and when running as an escript. Falls back
    # to searching next to the escript binary and CWD/priv.
    priv_from_app =
      case :code.priv_dir(:instantgrep) do
        {:error, _} -> nil
        dir ->
          base = Path.join([to_string(dir), "instantgrep_native"])
          if File.exists?(base <> ext), do: base, else: nil
      end

    priv_from_app ||
      Enum.find([
        Path.join([escript_dir(), "priv", "instantgrep_native"]),
        Path.join([File.cwd!(), "priv", "instantgrep_native"])
      ], fn base -> File.exists?(base <> ext) end)
  end

  defp escript_dir do
    case :init.get_argument(:progname) do
      {:ok, [[name | _]]} ->
        name |> to_string() |> Path.dirname() |> Path.absname()
      _ ->
        File.cwd!()
    end
  rescue
    _ -> File.cwd!()
  end

  # ---- NIF stubs — overridden at load time if the .so is present ----

  @doc false
  def compile_pattern_nif(_pattern, _flags),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def scan_content_nif(_resource, _content),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def extract_trigrams_nif(_content),
    do: :erlang.nif_error(:nif_not_loaded)
end
