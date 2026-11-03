/* Known-answer checks over the vendored liblz4 (compress, decompress, frame). */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "lz4.h"
#include "lz4hc.h"
#include "lz4frame.h"

static int failures = 0;
#define CHECK(name, cond) do { if (cond) printf("PASS %s\n", name); else { printf("FAIL %s\n", name); failures++; } } while (0)

int main(void) {
    /* Hand-assembled block: token 0x50 = 5 literals, no match. */
    const char block[] = { 0x50, 'h', 'e', 'l', 'l', 'o' };
    char out[64];
    int n = LZ4_decompress_safe(block, out, (int)sizeof block, (int)sizeof out);
    CHECK("block_decompress_known", n == 5 && memcmp(out, "hello", 5) == 0);

    /* Truncated block must be rejected. */
    CHECK("block_decompress_truncated", LZ4_decompress_safe(block, out, 4, (int)sizeof out) < 0);

    /* One literal, then a 9-byte overlapping match at offset 1, then 5 trailing literals. */
    const char rle[] = { 0x15, 'a', 0x01, 0x00, 0x50, 'b', 'c', 'd', 'e', 'f' };
    memset(out, 0, sizeof out);
    n = LZ4_decompress_safe(rle, out, (int)sizeof rle, (int)sizeof out);
    CHECK("block_decompress_match", n == 15 && memcmp(out, "aaaaaaaaaabcdef", 15) == 0);

    char src[4096];
    for (size_t i = 0; i < sizeof src; i++) src[i] = (char)("abcabcabd"[i % 9]);
    char comp[LZ4_COMPRESSBOUND(4096)], back[4096];
    int c = LZ4_compress_default(src, comp, (int)sizeof src, (int)sizeof comp);
    CHECK("block_compress_shrinks", c > 0 && c < 200);
    CHECK("block_roundtrip", c > 0 && LZ4_decompress_safe(comp, back, c, (int)sizeof back) == (int)sizeof src && memcmp(src, back, sizeof src) == 0);
    c = LZ4_compress_HC(src, comp, (int)sizeof src, (int)sizeof comp, 9);
    CHECK("hc_roundtrip", c > 0 && LZ4_decompress_safe(comp, back, c, (int)sizeof back) == (int)sizeof src && memcmp(src, back, sizeof src) == 0);

    char frame[LZ4F_compressFrameBound(4096, NULL)];
    size_t fc = LZ4F_compressFrame(frame, sizeof frame, src, sizeof src, NULL);
    CHECK("frame_magic", !LZ4F_isError(fc) && memcmp(frame, "\x04\x22\x4d\x18", 4) == 0);
    LZ4F_dctx *ctx = NULL;
    size_t dsize = sizeof back, ssize = fc;
    memset(back, 0, sizeof back);
    int ok = !LZ4F_isError(LZ4F_createDecompressionContext(&ctx, LZ4F_VERSION)) &&
             LZ4F_decompress(ctx, back, &dsize, frame, &ssize, NULL) == 0 &&
             dsize == sizeof src && memcmp(src, back, sizeof src) == 0;
    LZ4F_freeDecompressionContext(ctx);
    CHECK("frame_roundtrip", ok);

    return failures ? 1 : 0;
}
