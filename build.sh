#!/bin/bash
# Build both instantgrep and instantgrep-bench escripts
set -e

echo "==> Fetching dependencies..."
mix deps.get

echo "==> Building PCRE2-JIT NIF and ig client..."
make all

echo "==> Compiling..."
mix compile

echo "==> Building instantgrep escript..."
mix escript.build

echo "==> Building instantgrep-bench escript..."
# Build the bench escript by temporarily switching the main_module
MIX_ENV=prod mix escript.build --name instantgrep-bench --main-module Instantgrep.Bench 2>/dev/null || \
  mix escript.build

echo ""
echo "Built:"
ls -la ig_client instantgrep instantgrep-bench 2>/dev/null || ls -la ig_client instantgrep
