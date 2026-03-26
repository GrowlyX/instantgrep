/*
 * ig.c — thin instantgrep client (replaces ig.py, no Python required).
 *
 * Connects directly to the daemon Unix socket, bypassing BEAM VM startup (~3s
 * saved per query).  Falls back to the full `instantgrep` escript if no daemon
 * is running.
 *
 * Usage:
 *     ig_client [OPTIONS] PATTERN [PATH]
 *
 * Options:
 *     -i, --ignore-case    Case-insensitive search
 *     -t, --time           Show timing breakdown
 *     -h, --help           Show this message
 *
 * Environment:
 *     IG_PATH    Default search path (overrides CWD)
 *
 * Build:
 *     cc -O2 -Wall -o ig_client c_src/ig.c
 */

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>

#define SOCK_NAME   "daemon.sock"
#define READ_BUF    65536

static const char USAGE[] =
    "ig_client — thin instantgrep client\n"
    "\n"
    "Connects directly to the daemon Unix socket, bypassing BEAM VM startup.\n"
    "Falls back to the full `instantgrep` escript if no daemon is running.\n"
    "\n"
    "Usage:\n"
    "    ig_client [OPTIONS] PATTERN [PATH]\n"
    "\n"
    "Options:\n"
    "    -i, --ignore-case    Case-insensitive search\n"
    "    -t, --time           Show timing breakdown\n"
    "    -h, --help           Show this message\n"
    "\n"
    "Environment:\n"
    "    IG_PATH    Default search path (overrides CWD)\n"
    "\n"
    "Examples:\n"
    "    ig_client \"some_rare_identifier\" /path/to/codebase/\n"
    "    ig_client -i \"todo\" .\n"
    "    ig_client --time \"std::string\"\n";

/* ---- helpers ---- */

static long long monotonic_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + (long long)ts.tv_nsec / 1000000;
}

static void make_socket_path(const char *base_dir, char *out, size_t n) {
    int r = snprintf(out, n, "%s/.instantgrep/%s", base_dir, SOCK_NAME);
    if (r < 0 || (size_t)r >= n) {
        fprintf(stderr, "ig: socket path too long\n");
        exit(1);
    }
}

/* Return true if the file at path exists. */
static int file_exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0;
}

/*
 * Resolve the directory that contains the running `ig` binary.
 * On Linux we use /proc/self/exe; elsewhere we fall back to argv[0].
 */
static void self_dir(const char *argv0, char *out, size_t n) {
#ifdef __linux__
    char buf[PATH_MAX];
    ssize_t len = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (len > 0) {
        buf[len] = '\0';
        char *slash = strrchr(buf, '/');
        if (slash) {
            *slash = '\0';
            snprintf(out, n, "%s", buf);
            return;
        }
    }
#endif
    /* fallback: dirname of argv[0] */
    char buf2[PATH_MAX];
    snprintf(buf2, sizeof(buf2), "%s", argv0);
    char *slash = strrchr(buf2, '/');
    if (slash) {
        *slash = '\0';
        snprintf(out, n, "%s", buf2);
    } else {
        snprintf(out, n, ".");
    }
}

/* ---- daemon search ---- */

/*
 * Connect to the daemon socket and stream results to stdout.
 * Returns 1 on success, 0 if the daemon is not reachable.
 */
static int search_via_daemon(const char *sock_path, const char *pattern,
                             int ignore_case, int show_time) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return 0;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (strlen(sock_path) >= sizeof(addr.sun_path)) {
        close(fd);
        return 0;
    }
    strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path) - 1);

    /* 3-second connect timeout via SO_RCVTIMEO on the blocking connect */
    struct timeval tv = {3, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return 0;
    }

    /* Remove 3s timeout once connected — we want to drain fully. */
    tv.tv_sec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    /* Send query: "<pattern>\t<ic>\n" */
    {
        char query[4096 + 4];
        int qlen = snprintf(query, sizeof(query), "%s\t%c\n",
                            pattern, ignore_case ? '1' : '0');
        if (qlen < 0 || (size_t)qlen >= sizeof(query) ||
            write(fd, query, (size_t)qlen) != qlen) {
            close(fd);
            return 0;
        }
    }

    long long t_start = monotonic_ms();

    /* Read and process lines. */
    char   buf[READ_BUF];
    size_t used = 0;
    int    done = 0, error = 0;

    while (!done) {
        ssize_t n = read(fd, buf + used, sizeof(buf) - used - 1);
        if (n <= 0) break;
        used += (size_t)n;
        buf[used] = '\0';

        /* Process every complete line in the buffer. */
        char *line = buf;
        char *nl;
        while ((nl = memchr(line, '\n', (size_t)(buf + used - line))) != NULL) {
            *nl = '\0';

            if (strncmp(line, "\\DONE\t", 6) == 0) {
                /* \DONE\t<ms>\t<candidates>\t<matches> */
                if (show_time) {
                    long long wall_ms = monotonic_ms() - t_start;
                    char *p = line + 6;
                    const char *elapsed_ms  = strtok(p, "\t");
                    const char *candidates  = strtok(NULL, "\t");
                    const char *matches     = strtok(NULL, "\t");
                    if (!elapsed_ms)  elapsed_ms  = "?";
                    if (!candidates)  candidates  = "?";
                    if (!matches)     matches     = "?";
                    fprintf(stderr,
                            "\n--- timing via daemon (pattern: %s) ---\n"
                            "  index load:    0ms  (index resident in daemon)\n"
                            "  search:        %sms  (%s candidates, %s matches)\n"
                            "  wall (client): %lldms  (socket round-trip)\n",
                            pattern, elapsed_ms, candidates, matches, wall_ms);
                }
                done = 1;
            } else if (strncmp(line, "\\ERROR\t", 7) == 0) {
                fprintf(stderr, "ig: daemon error: %s\n", line + 7);
                error = 1;
                done  = 1;
            } else {
                puts(line);
            }

            line = nl + 1;
        }

        /* Shift unconsumed bytes to the front. */
        used = (size_t)(buf + used - line);
        memmove(buf, line, used);
    }

    close(fd);
    return done && !error;
}

/* ---- escript fallback ---- */

static void fallback_escript(const char *argv0, const char *pattern,
                              const char *path, int ignore_case, int show_time) {
    char dir[PATH_MAX];
    self_dir(argv0, dir, sizeof(dir));

    char ig_bin[PATH_MAX];
    {
        int r = snprintf(ig_bin, sizeof(ig_bin), "%s/instantgrep", dir);
        if (r < 0 || (size_t)r >= sizeof(ig_bin)) {
            fprintf(stderr, "ig: instantgrep path too long\n");
            exit(1);
        }
    }

    if (!file_exists(ig_bin)) {
        fprintf(stderr, "ig: cannot find 'instantgrep' binary next to this executable\n");
        exit(1);
    }

    fprintf(stderr, "ig: no daemon running — starting full escript (slow cold start)…\n");

    /* Build argv for execv */
    const char *args[8];
    int ai = 0;
    args[ai++] = ig_bin;
    if (ignore_case) args[ai++] = "-i";
    if (show_time)   args[ai++] = "--time";
    args[ai++] = pattern;
    if (path && path[0]) args[ai++] = path;
    args[ai] = NULL;

    execv(ig_bin, (char *const *)args);
    /* execv only returns on error */
    fprintf(stderr, "ig: execv failed: %s\n", strerror(errno));
    exit(1);
}

/* ---- argument parsing ---- */

typedef struct {
    int         ignore_case;
    int         show_time;
    const char *pattern;
    const char *path;
} Args;

static Args parse_args(int argc, char *argv[]) {
    Args a = {0, 0, NULL, NULL};
    const char *positional[2] = {NULL, NULL};
    int npos = 0;

    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];
        if (strcmp(arg, "-i") == 0 || strcmp(arg, "--ignore-case") == 0) {
            a.ignore_case = 1;
        } else if (strcmp(arg, "-t") == 0 || strcmp(arg, "--time") == 0) {
            a.show_time = 1;
        } else if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
            fputs(USAGE, stdout);
            exit(0);
        } else if (arg[0] == '-') {
            fprintf(stderr, "ig: unknown option: %s\n", arg);
            exit(1);
        } else if (npos < 2) {
            positional[npos++] = arg;
        }
    }

    if (npos >= 1) a.pattern = positional[0];
    if (npos >= 2) a.path    = positional[1];
    return a;
}

/* ---- main ---- */

int main(int argc, char *argv[]) {
    Args a = parse_args(argc, argv);

    if (!a.pattern) {
        fputs(USAGE, stdout);
        return 1;
    }

    /* Resolve search path: CLI arg > IG_PATH env > cwd */
    char path_buf[PATH_MAX];
    if (a.path) {
        if (!realpath(a.path, path_buf)) {
            fprintf(stderr, "ig: cannot resolve path '%s': %s\n",
                    a.path, strerror(errno));
            return 1;
        }
    } else {
        const char *env_path = getenv("IG_PATH");
        if (env_path) {
            if (!realpath(env_path, path_buf)) {
                fprintf(stderr, "ig: cannot resolve IG_PATH '%s': %s\n",
                        env_path, strerror(errno));
                return 1;
            }
        } else {
            if (!getcwd(path_buf, sizeof(path_buf))) {
                fprintf(stderr, "ig: getcwd failed: %s\n", strerror(errno));
                return 1;
            }
        }
    }

    char sock[PATH_MAX];
    make_socket_path(path_buf, sock, sizeof(sock));

    if (file_exists(sock)) {
        if (search_via_daemon(sock, a.pattern, a.ignore_case, a.show_time))
            return 0;
    }

    fallback_escript(argv[0], a.pattern, path_buf, a.ignore_case, a.show_time);
    /* unreachable — fallback_escript exits or execs */
    return 1;
}
