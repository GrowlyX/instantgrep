#!/bin/bash
# Instantgrep CLI wrapper

SOCKET="${TMPDIR:-/tmp}/instantgrep_${USER}.sock"

# Try to resolve the directory of this script to find the daemon
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DAEMON="$DIR/instantgrep-daemon"

# Fallback checking if it is in PATH
if [ ! -x "$DAEMON" ]; then
  if command -v instantgrep-daemon >/dev/null 2>&1; then
    DAEMON="instantgrep-daemon"
  fi
fi

if ! nc -z -U "$SOCKET" 2>/dev/null; then
  if [ ! -x "$DAEMON" ] && ! command -v "$DAEMON" >/dev/null 2>&1; then
    echo "Error: instantgrep-daemon not found in $DIR or PATH" >&2
    exit 1
  fi
  
  "$DAEMON" --daemon &
  
  # Wait for the socket to be created
  max_retries=20
  while [ ! -S "$SOCKET" ] && [ $max_retries -gt 0 ]; do
    sleep 0.05
    max_retries=$((max_retries - 1))
  done
  
  if [ ! -S "$SOCKET" ]; then
    echo "Error: Daemon failed to start or create socket at $SOCKET" >&2
    exit 1
  fi
fi

# Send arguments separated by null bytes to the daemon
printf "%s\0" "$@" | nc -U "$SOCKET"
