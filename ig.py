#!/usr/bin/env python3
"""
ig.py — thin instantgrep client.

Connects directly to the daemon Unix socket, bypassing BEAM VM startup (~3s saved per query).
Falls back to the full `instantgrep` escript if no daemon is running.

Usage:
    ig.py [OPTIONS] PATTERN [PATH]

Options:
    -i, --ignore-case    Case-insensitive search
    -t, --time           Show timing breakdown
    -h, --help           Show this message

Environment:
    IG_PATH    Default search path (overrides CWD)

Examples:
    python3 ig.py "some_rare_identifier" /path/to/codebase/
    python3 ig.py -i "todo" .
    python3 ig.py --time "std::string"
"""

import socket
import sys
import os
import time
import subprocess

SOCK_NAME = "daemon.sock"


def socket_path(base_dir: str) -> str:
    return os.path.join(base_dir, ".instantgrep", SOCK_NAME)


def parse_args(argv):
    args = {"ignore_case": False, "time": False, "pattern": None, "path": None}
    i = 1
    positional = []
    while i < len(argv):
        a = argv[i]
        if a in ("-i", "--ignore-case"):
            args["ignore_case"] = True
        elif a in ("-t", "--time"):
            args["time"] = True
        elif a in ("-h", "--help"):
            print(__doc__)
            sys.exit(0)
        elif a.startswith("-"):
            print(f"ig: unknown option: {a}", file=sys.stderr)
            sys.exit(1)
        else:
            positional.append(a)
        i += 1

    if len(positional) >= 1:
        args["pattern"] = positional[0]
    if len(positional) >= 2:
        args["path"] = positional[1]

    return args


def search_via_daemon(sock: str, pattern: str, ignore_case: bool, show_time: bool):
    """Connect to daemon socket and stream results. Returns True on success."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(3.0)
            s.connect(sock)
            s.settimeout(None)

            ic = "1" if ignore_case else "0"
            s.sendall(f"{pattern}\t{ic}\n".encode())

            buf = b""
            stdout_fd = sys.stdout.fileno()
            t_start = time.monotonic()

            while True:
                chunk = s.recv(65536)
                if not chunk:
                    break
                buf += chunk

                # Scan for terminal markers without splitting every line
                while True:
                    nl = buf.find(b"\n")
                    if nl < 0:
                        break

                    line_bytes = buf[:nl]
                    buf = buf[nl + 1:]

                    if line_bytes.startswith(b"\\DONE\t"):
                        parts = line_bytes.decode(errors="replace").split("\t")
                        elapsed_ms = parts[1] if len(parts) > 1 else "?"
                        candidates  = parts[2] if len(parts) > 2 else "?"
                        matches     = parts[3] if len(parts) > 3 else "?"
                        if show_time:
                            wall_ms = int((time.monotonic() - t_start) * 1000)
                            print(
                                f"\n--- timing via daemon (pattern: {pattern!r}) ---",
                                file=sys.stderr,
                            )
                            print(
                                "  index load:    0ms  (index resident in daemon)",
                                file=sys.stderr,
                            )
                            print(
                                f"  search:        {elapsed_ms}ms  ({candidates} candidates, {matches} matches)",
                                file=sys.stderr,
                            )
                            print(
                                f"  wall (client): {wall_ms}ms  (socket round-trip)",
                                file=sys.stderr,
                            )
                        return True

                    if line_bytes.startswith(b"\\ERROR\t"):
                        msg = line_bytes[7:].decode(errors="replace")
                        print(f"ig: daemon error: {msg}", file=sys.stderr)
                        return False

                    # Write result line directly to stdout fd — avoids Python print() overhead
                    os.write(stdout_fd, line_bytes + b"\n")

    except (ConnectionRefusedError, FileNotFoundError, OSError):
        return False  # daemon not running → fall back

    return True


def fallback_escript(pattern: str, path: str, ignore_case: bool, show_time: bool):
    """Fall back to full instantgrep escript invocation."""
    script_dir = os.path.dirname(os.path.realpath(__file__))
    ig_bin = os.path.join(script_dir, "instantgrep")

    if not os.path.isfile(ig_bin):
        print("ig: cannot find 'instantgrep' binary next to this script", file=sys.stderr)
        sys.exit(1)

    cmd = [ig_bin]
    if ignore_case:
        cmd.append("-i")
    if show_time:
        cmd.append("--time")
    cmd.append(pattern)
    if path:
        cmd.append(path)

    print(
        "ig: no daemon running — starting full escript (slow cold start)…",
        file=sys.stderr,
    )
    result = subprocess.run(cmd)
    sys.exit(result.returncode)


def main():
    args = parse_args(sys.argv)

    if args["pattern"] is None:
        print(__doc__)
        sys.exit(1)

    # Resolve search path: CLI arg > IG_PATH env > cwd
    path = args["path"] or os.environ.get("IG_PATH") or os.getcwd()
    path = os.path.realpath(path)

    sock = socket_path(path)

    if os.path.exists(sock):
        ok = search_via_daemon(sock, args["pattern"], args["ignore_case"], args["time"])
        if ok:
            return

    # Daemon not available — fall back to escript
    fallback_escript(args["pattern"], path, args["ignore_case"], args["time"])


if __name__ == "__main__":
    main()
