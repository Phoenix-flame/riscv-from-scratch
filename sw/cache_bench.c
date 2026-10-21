/* cache_bench.c - Step 43 workload: three memory-access patterns whose cost
 * depends on the caches in very different ways.
 *
 *   reuse  : 256 words (1 KiB) written once, then read 8 times. Fits in the
 *            2 KiB D-cache: after the first pass every load hits.
 *   sort   : insertion sort of 128 of those words -- a tight loop with lots
 *            of nearby loads and stores (and lots of instruction reuse).
 *   stream : an 8 KiB array (4x the D-cache) read one word per 32-byte line,
 *            twice. Every load is a miss; the second pass cannot hit either.
 *
 * Each phase prints a checksum. The same file builds natively on the host
 * (-DHOST) to produce the expected output, so the check does not trust the
 * core under test. The arrays sit at fixed RAM addresses above the stack. */
#ifdef HOST
#include <stdio.h>
static unsigned A_buf[256], BIG_buf[2048];
#define A   A_buf
#define BIG BIG_buf
#define kprintf printf
#define halt(c) return 0
#else
#include "firmware.h"
#define A   ((volatile unsigned *)0x4000)   /* 1 KiB: fits the D-cache   */
#define BIG ((volatile unsigned *)0x5000)   /* 8 KiB: four times too big */
#endif

static unsigned seed = 1;
static unsigned lcg(void){ seed = seed * 1103515245u + 12345u; return seed >> 8; }

int main(void){
    unsigned i, p, sum, chk, v;
    int j;

    for (i = 0; i < 256; i++) A[i] = lcg() & 0xFFFFu;
    sum = 0;
    for (p = 0; p < 8; p++)
        for (i = 0; i < 256; i++) sum += A[i] * (p + 1);
    kprintf("reuse  : %u\n", sum);

    for (i = 1; i < 128; i++) {
        v = A[i]; j = (int)i - 1;
        while (j >= 0 && A[j] > v) { A[j + 1] = A[j]; j--; }
        A[j + 1] = v;
    }
    chk = 0;
    for (i = 0; i < 128; i++) chk = chk * 31u + A[i];
    kprintf("sort   : %u\n", chk);

    for (i = 0; i < 2048; i++) BIG[i] = i * 7u + 3u;
    sum = 0;
    for (p = 0; p < 2; p++)
        for (i = 0; i < 2048; i += 8) sum += BIG[i];
    kprintf("stream : %u\n", sum);

    kprintf("CACHE BENCH OK\n");
    halt(0);
}
