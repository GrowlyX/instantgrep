#!/bin/bash
# Build both instantgrep and instantgrep-bench escripts
set -e

echo "==> Fetching dependencies..."
mix deps.get

echo "==> Compiling..."
mix compile

echo "==> Building instantgrep-daemon escript..."
mix escript.build

echo "==> Setting up instantgrep wrapper..."
cp cli_wrapper.sh instantgrep
chmod +x instantgrep

echo "==> Building instantgrep-bench escript..."
# Build the bench escript by temporarily switching the main_module
MIX_ENV=prod mix escript.build --name instantgrep-bench --main-module Instantgrep.Bench 2>/dev/null || \
  mix escript.build

echo ""
echo "Built:"
ls -la instantgrep instantgrep-daemon instantgrep-bench 2>/dev/null || ls -la instantgrep instantgrep-daemon
