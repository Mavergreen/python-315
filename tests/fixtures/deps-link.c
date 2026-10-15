#include <stdio.h>
#include <string.h>
#include <lzma.h>
#include <zstd.h>
#include <zdict.h>
#include <sqlite3.h>

static int failures;
static void check(int ok, const char *what) {
  if (!ok) { fprintf(stderr, "deps-link: %s failed\n", what); failures++; }
}

int main(void) {
  static uint8_t in[8192], enc[16384], dec[8192], samples[64 * 100];
  size_t i, enc_pos = 0, in_pos = 0, dec_pos = 0;
  for (i = 0; i < sizeof in; i++) in[i] = (uint8_t)(i % 251);

  check(lzma_crc64(in, sizeof in, 0) != 0 && lzma_crc32(in, sizeof in, 0) != 0, "xz check: lzma_crc64/lzma_crc32");
  check(lzma_easy_buffer_encode(6, LZMA_CHECK_SHA256, NULL, in, sizeof in, enc, &enc_pos, sizeof enc) == LZMA_OK,
        "xz common/lzma/lz/rangecoder: lzma_easy_buffer_encode");
  uint64_t memlimit = UINT64_MAX;
  check(lzma_stream_buffer_decode(&memlimit, 0, NULL, enc, &in_pos, enc_pos, dec, &dec_pos, sizeof dec) == LZMA_OK
          && dec_pos == sizeof in && memcmp(in, dec, sizeof in) == 0,
        "xz common: lzma_stream_buffer_decode round trip");

  lzma_options_lzma lzma_opt;
  check(!lzma_lzma_preset(&lzma_opt, 6), "xz lzma: lzma_lzma_preset");
  lzma_options_delta delta_opt = { .type = LZMA_DELTA_TYPE_BYTE, .dist = 4 };
  lzma_filter chain[] = {
    { .id = LZMA_FILTER_DELTA, .options = &delta_opt },
    { .id = LZMA_FILTER_X86, .options = NULL },
    { .id = LZMA_FILTER_LZMA2, .options = &lzma_opt },
    { .id = LZMA_VLI_UNKNOWN, .options = NULL },
  };
  enc_pos = 0;
  check(lzma_raw_buffer_encode(chain, NULL, in, sizeof in, enc, &enc_pos, sizeof enc) == LZMA_OK,
        "xz delta/simple: lzma_raw_buffer_encode with delta and x86 filters");

  lzma_stream strm = LZMA_STREAM_INIT;
  check(lzma_easy_encoder(&strm, 6, LZMA_CHECK_CRC64) == LZMA_OK, "xz common: lzma_easy_encoder");
  lzma_end(&strm);
  lzma_mt mt = { .threads = 2, .preset = 6, .check = LZMA_CHECK_CRC32 };
  check(lzma_stream_encoder_mt(&strm, &mt) == LZMA_OK, "xz common: lzma_stream_encoder_mt");
  lzma_end(&strm);
  check(lzma_stream_decoder(&strm, UINT64_MAX, 0) == LZMA_OK, "xz common: lzma_stream_decoder");
  lzma_end(&strm);
  check(lzma_physmem() > 0 && lzma_cputhreads() > 0, "xz tuklib: lzma_physmem/lzma_cputhreads");

  size_t zn = ZSTD_compress(enc, sizeof enc, in, sizeof in, 3);
  check(!ZSTD_isError(zn), "zstd compress: ZSTD_compress");
  size_t zd = ZSTD_decompress(dec, sizeof dec, enc, zn);
  check(zd == sizeof in && memcmp(in, dec, sizeof in) == 0, "zstd decompress: ZSTD_decompress round trip");
  ZSTD_CCtx *cctx = ZSTD_createCCtx();
  check(!ZSTD_isError(ZSTD_CCtx_setParameter(cctx, ZSTD_c_nbWorkers, 2)), "zstd mt: ZSTD_c_nbWorkers");
  ZSTD_freeCCtx(cctx);
  size_t sizes[100];
  for (i = 0; i < 100; i++) sizes[i] = 64;
  for (i = 0; i < sizeof samples; i++) samples[i] = (uint8_t)((i * 7) % 13);
  size_t dn = ZDICT_trainFromBuffer(enc, sizeof enc, samples, sizes, 100);
  printf("zstd dictBuilder: ZDICT_trainFromBuffer -> %s\n", ZDICT_isError(dn) ? ZDICT_getErrorName(dn) : "dictionary");

  sqlite3 *db;
  char *err = NULL;
  check(sqlite3_open(":memory:", &db) == SQLITE_OK, "sqlite: sqlite3_open");
  check(sqlite3_exec(db, "create virtual table f using fts5(x); create virtual table r using rtree(id, a, b);"
                         " select sqrt(4);", NULL, NULL, &err) == SQLITE_OK, "sqlite: FTS5, R*Tree, math functions");
  if (err) fprintf(stderr, "deps-link: sqlite: %s\n", err);
  sqlite3_close(db);

  printf("lzma %s, zstd %s, sqlite %s\n", lzma_version_string(), ZSTD_versionString(), sqlite3_libversion());
  return failures ? 1 : 0;
}
