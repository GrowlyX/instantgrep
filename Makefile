# Makefile — builds the PCRE2-JIT NIF for instantgrep
#
# Usage:
#   make            — build priv/instantgrep_native.so
#   make clean      — remove build output
#
# Requires: libpcre2-dev (Debian/Ubuntu) or pcre2 (Homebrew on macOS)

# --- ERTS include path (computed at build time via erl) ---
ERTS_INCLUDE := $(shell erl -noshell \
    -eval 'io:format("~s/erts-~s/include",[code:root_dir(),erlang:system_info(version)])' \
    -s init stop 2>/dev/null)

ifeq ($(ERTS_INCLUDE),)
  $(error Cannot find ERTS include dir. Is Erlang/OTP installed and on PATH?)
endif

# --- PCRE2 flags (pkg-config preferred, fallback to -lpcre2-8) ---
PCRE2_CFLAGS  := $(shell pkg-config --cflags libpcre2-8 2>/dev/null)
PCRE2_LDFLAGS := $(shell pkg-config --libs   libpcre2-8 2>/dev/null || echo "-lpcre2-8")

PRIV_DIR = priv
NIF_SO   = $(PRIV_DIR)/instantgrep_native.so
SRC      = c_src/instantgrep_native.c

IG_BIN   = ig_client
IG_SRC   = c_src/ig.c

CFLAGS  = -O2 -Wall -Wextra -fPIC -I$(ERTS_INCLUDE) $(PCRE2_CFLAGS)
LDFLAGS = -shared -fPIC $(PCRE2_LDFLAGS)

# macOS uses different link flags
ifeq ($(shell uname -s),Darwin)
  NIF_SO   = $(PRIV_DIR)/instantgrep_native.so
  LDFLAGS  = -dynamiclib -undefined dynamic_lookup $(PCRE2_LDFLAGS)
endif

# --- Targets ---

.PHONY: all clean

all: $(NIF_SO) $(IG_BIN)

$(NIF_SO): $(SRC) | $(PRIV_DIR)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)
	@echo "  NIF built: $@"

# ig is a plain C binary — no ERTS headers, no PCRE2 needed
$(IG_BIN): $(IG_SRC)
	$(CC) -O2 -Wall -Wextra -o $@ $<
	@echo "  ig_client built: $@"

$(PRIV_DIR):
	mkdir -p $(PRIV_DIR)

clean:
	rm -f $(NIF_SO) $(IG_BIN)
