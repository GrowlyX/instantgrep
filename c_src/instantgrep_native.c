/*
 * instantgrep_native.c — PCRE2-JIT NIF for fast content scanning.
 *
 * Replaces Erlang's :re.run (PCRE1, no JIT) with PCRE2 + JIT compilation.
 *
 * Exported NIFs:
 *   compile_pattern_nif(pattern_binary, flags_int) -> {:ok, resource} | {:error, binary}
 *   scan_content_nif(resource, content_binary)     -> [{offset, len}, ...]
 *
 * flags_int bits:
 *   bit 0 — PCRE2_CASELESS (ignore-case)
 *
 * scan_content_nif is declared ERL_NIF_DIRTY_JOB_CPU_BOUND so large file scans
 * never block normal BEAM schedulers.
 *
 * Build (Linux):
 *   cc -O2 -Wall -fPIC -shared \
 *      -I$(ERTS_INCLUDE) $(pkg-config --cflags libpcre2-8) \
 *      -o priv/instantgrep_native.so c_src/instantgrep_native.c \
 *      $(pkg-config --libs libpcre2-8)
 *
 * Requires: libpcre2-dev (apt) / pcre2 (brew)
 */

#define PCRE2_CODE_UNIT_WIDTH 8
#include <pcre2.h>
#include <erl_nif.h>
#include <string.h>
#include <stdint.h>

/* ---- Resource type for compiled PCRE2 patterns ---- */

static ErlNifResourceType *pcre2_res_type;

typedef struct {
    pcre2_code *re;
    int         jit_available;
} Pcre2Resource;

static void pcre2_res_destructor(ErlNifEnv *env, void *obj)
{
    (void)env;
    Pcre2Resource *r = (Pcre2Resource *)obj;
    if (r->re) {
        pcre2_code_free(r->re);
        r->re = NULL;
    }
}

/* ---- compile_pattern_nif/2 ---- */

static ERL_NIF_TERM nif_compile_pattern(ErlNifEnv *env, int argc,
                                         const ERL_NIF_TERM argv[])
{
    (void)argc;
    ErlNifBinary pat;
    int flags;

    if (!enif_inspect_binary(env, argv[0], &pat)) return enif_make_badarg(env);
    if (!enif_get_int(env, argv[1], &flags))       return enif_make_badarg(env);

    uint32_t opts = PCRE2_UTF | PCRE2_NEVER_BACKSLASH_C;
    if (flags & 1) opts |= PCRE2_CASELESS;

    int        errcode;
    PCRE2_SIZE erroffset;

    pcre2_code *re = pcre2_compile(
        (PCRE2_SPTR)pat.data, (PCRE2_SIZE)pat.size,
        opts, &errcode, &erroffset, NULL);

    if (!re) {
        PCRE2_UCHAR errbuf[256];
        pcre2_get_error_message(errcode, errbuf, sizeof(errbuf));
        size_t len = strlen((const char *)errbuf);
        ErlNifBinary eb;
        enif_alloc_binary(len, &eb);
        memcpy(eb.data, errbuf, len);
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_binary(env, &eb));
    }

    /* JIT compile — harmless no-op if platform lacks JIT support */
    int jit_ok = (pcre2_jit_compile(re, PCRE2_JIT_COMPLETE) == 0);

    Pcre2Resource *res = (Pcre2Resource *)enif_alloc_resource(pcre2_res_type,
                                                               sizeof(Pcre2Resource));
    res->re            = re;
    res->jit_available = jit_ok;

    ERL_NIF_TERM term = enif_make_resource(env, res);
    enif_release_resource(res); /* hand ownership to Erlang GC */

    return enif_make_tuple2(env, enif_make_atom(env, "ok"), term);
}

/* ---- scan_content_nif/2  (runs on dirty CPU scheduler) ---- */

static ERL_NIF_TERM nif_scan_content(ErlNifEnv *env, int argc,
                                      const ERL_NIF_TERM argv[])
{
    (void)argc;
    Pcre2Resource *res;
    ErlNifBinary   content;

    if (!enif_get_resource(env, argv[0], pcre2_res_type, (void **)&res))
        return enif_make_badarg(env);
    if (!enif_inspect_binary(env, argv[1], &content))
        return enif_make_badarg(env);

    pcre2_match_data *md = pcre2_match_data_create_from_pattern(res->re, NULL);
    if (!md) return enif_make_list(env, 0);

    /*
     * Build result list by prepending into a singly-linked list,
     * then reverse once at the end — avoids quadratic list construction.
     */
    ERL_NIF_TERM list  = enif_make_list(env, 0); /* [] */
    PCRE2_SIZE   start = 0;
    int          rc;

    while (start <= (PCRE2_SIZE)content.size) {
        if (res->jit_available) {
            rc = pcre2_jit_match(res->re,
                                 (PCRE2_SPTR)content.data,
                                 (PCRE2_SIZE)content.size,
                                 start, 0, md, NULL);
        } else {
            rc = pcre2_match(res->re,
                             (PCRE2_SPTR)content.data,
                             (PCRE2_SIZE)content.size,
                             start, 0, md, NULL);
        }

        if (rc < 0) break; /* PCRE2_ERROR_NOMATCH or unrecoverable error */

        PCRE2_SIZE *ov      = pcre2_get_ovector_pointer(md);
        PCRE2_SIZE  mstart  = ov[0];
        PCRE2_SIZE  mend    = ov[1];

        /* {offset, length} — identical shape to :re.run and :binary.matches */
        ERL_NIF_TERM tup = enif_make_tuple2(env,
            enif_make_ulong(env, (unsigned long)mstart),
            enif_make_ulong(env, (unsigned long)(mend - mstart)));

        list = enif_make_list_cell(env, tup, list);

        /* Advance past this match; handle zero-length matches by stepping one */
        start = (mend > start) ? mend : mend + 1;
    }

    pcre2_match_data_free(md);

    /* Reverse to restore ascending offset order */
    ERL_NIF_TERM reversed;
    if (!enif_make_reverse_list(env, list, &reversed))
        return enif_make_list(env, 0);

    return reversed;
}

/* ---- extract_trigrams_nif/1 (dirty CPU) ---- */
/*
 * Extracts all unique overlapping 3-byte trigrams from a binary in a single
 * pass using an open-addressing hash table (linear probing).
 *
 * Returns [{trigram_int, next_mask, loc_mask}] in arbitrary order where:
 *   trigram_int = byte0<<16 | byte1<<8 | byte2  (24-bit unsigned integer)
 *   next_mask   = 8-bit bloom filter of the byte immediately after the trigram
 *   loc_mask    = bitmask with bit (pos & 7) set for each occurrence position
 *
 * The table is allocated via enif_alloc (BEAM allocator, never OS-blocks).
 * Marked dirty because files up to 1 MB can take up to ~10 ms of CPU time.
 */

typedef struct {
    uint32_t key;       /* 24-bit trigram int; 0xFFFFFFFF = empty sentinel */
    uint8_t  next_mask;
    uint8_t  loc_mask;
} TrigEntry;

static ERL_NIF_TERM nif_extract_trigrams(ErlNifEnv *env, int argc,
                                          const ERL_NIF_TERM argv[])
{
    (void)argc;
    ErlNifBinary content;
    if (!enif_inspect_binary(env, argv[0], &content))
        return enif_make_badarg(env);

    size_t len = content.size;
    if (len < 3)
        return enif_make_list(env, 0);

    size_t n_pos = len - 2;   /* number of trigram start positions */

    /* Smallest power-of-2 capacity that keeps load factor <= 50 %, capped at 2 M. */
    size_t capacity = 64;
    while (capacity < n_pos * 2 && capacity < (1u << 21))
        capacity <<= 1;

    uint32_t cap_mask = (uint32_t)(capacity - 1);

    TrigEntry *table = (TrigEntry *)enif_alloc(capacity * sizeof(TrigEntry));
    if (!table)
        return enif_make_list(env, 0);

    /* Mark every slot empty: key = 0xFFFFFFFF is not a valid 24-bit value. */
    memset(table, 0xFF, capacity * sizeof(TrigEntry));

    const uint8_t *data = content.data;

    for (size_t i = 0; i < n_pos; i++) {
        uint32_t key     = ((uint32_t)data[i] << 16)
                         | ((uint32_t)data[i + 1] << 8)
                         |  (uint32_t)data[i + 2];
        uint8_t loc_bit  = (uint8_t)(1u << (i & 7u));
        uint8_t next_bit = (i + 3 < len)
                         ? (uint8_t)(1u << (data[i + 3] & 7u))
                         : 0u;

        /* Mix all three bytes so hot runs (e.g. spaces) don't cluster on one slot. */
        uint32_t h = ((key >> 16) ^ (key >> 8) ^ key) & cap_mask;

        while (table[h].key != 0xFFFFFFFFu && table[h].key != key)
            h = (h + 1u) & cap_mask;

        if (table[h].key == 0xFFFFFFFFu) {
            table[h].key       = key;
            table[h].next_mask = next_bit;
            table[h].loc_mask  = loc_bit;
        } else {
            table[h].next_mask |= next_bit;
            table[h].loc_mask  |= loc_bit;
        }
    }

    /* Convert occupied slots to an Erlang list.  Order is unimportant. */
    ERL_NIF_TERM list = enif_make_list(env, 0);
    for (size_t i = 0; i < capacity; i++) {
        if (table[i].key != 0xFFFFFFFFu) {
            ERL_NIF_TERM tup = enif_make_tuple3(env,
                enif_make_uint(env, table[i].key),
                enif_make_uint(env, table[i].next_mask),
                enif_make_uint(env, table[i].loc_mask));
            list = enif_make_list_cell(env, tup, list);
        }
    }

    enif_free(table);
    return list;
}

/* ---- NIF module init ---- */

static int nif_load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info)
{
    (void)priv_data;
    (void)load_info;

    ErlNifResourceFlags flags = ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER;
    pcre2_res_type = enif_open_resource_type(env, NULL, "pcre2_pattern",
                                              pcre2_res_destructor, flags, NULL);
    return (pcre2_res_type != NULL) ? 0 : -1;
}

static ErlNifFunc nif_funcs[] = {
    {"compile_pattern_nif",  2, nif_compile_pattern,  0},
    {"scan_content_nif",     2, nif_scan_content,     ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"extract_trigrams_nif", 1, nif_extract_trigrams, 0}
};

ERL_NIF_INIT(Elixir.Instantgrep.Native, nif_funcs, nif_load, NULL, NULL, NULL)
