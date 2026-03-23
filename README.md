# igrep

Fast regex search using trigram indexes. Based on [Cursor's research](https://cursor.com/blog/fast-regex-search).

Builds a trigram inverted index over your codebase and uses it to skip files that can't possibly match — **14x–80x faster** than grep/ripgrep on indexed repos.

## Install

```bash
brew tap GrowlyX/igrep
brew install igrep
```

Or build from source:

```bash
mix deps.get && mix escript.build
```

## Usage

```bash
igrep "pattern" path/          # search (builds index on first run)
igrep --build .                # build/rebuild index
igrep -i "todo|fixme" src/     # case-insensitive
igrep --no-index "pattern" .   # brute-force mode (no index)
```

## Benchmark

```bash
./igrep-bench lib/
./igrep-bench --patterns patterns.txt --iterations 10 /path/to/project
```

## How it works
[Cursor's research](https://cursor.com/blog/fast-regex-search)

1. **Index** — Extracts all overlapping 3-byte trigrams from every file, stores in an inverted index with bloom-filter masks
2. **Query** — Decomposes your regex into required trigrams
3. **Filter** — Looks up trigrams in the index to find candidate files
4. **Verify** — Runs full regex only on candidates

## License

MIT
