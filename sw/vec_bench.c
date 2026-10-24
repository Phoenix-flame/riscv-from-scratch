/* vec_bench.c - Step 47: the same kernels written scalar and with RVV
 * intrinsics, timed with the machine timer (one tick per clock) on
 * soc_pipe_u. Every vector result is checked against the scalar one.
 *
 *   vadd   c[i] = a[i] + b[i]                    256 x int32
 *   saxpy  y[i] = 3 * x[i] + y[i]                256 x int32
 *   dot    sum a[i] * b[i]                       256 x int32 (vredsum)
 *   copy   memcpy                                1 KiB, e8 / LMUL=8
 *
 * The vector unit is element-serial (one element per clock), so the gain
 * comes from not fetching, decoding and branching per element: a scalar
 * loop spends ~5-6 instructions per element, a vector strip-mined loop a
 * handful of instructions per VLMAX elements. Built with
 * -fno-tree-vectorize so the scalar loops stay scalar. */
#include "firmware.h"
#include <riscv_vector.h>

typedef int32_t i32;

#define N      256
#define A      ((i32 *)0x4000)
#define B      ((i32 *)0x4400)
#define C      ((i32 *)0x4800)
#define D      ((i32 *)0x4c00)
#define MTIME  (*(volatile unsigned *)0x10010000)

static unsigned seed = 1;
static unsigned lcg(void){ seed = seed * 1103515245u + 12345u; return seed >> 8; }

static void vadd_s(i32 *c, const i32 *a, const i32 *b, int n){ for (int i = 0; i < n; i++) c[i] = a[i] + b[i]; }
static void vadd_v(i32 *c, const i32 *a, const i32 *b, int n){
    for (size_t vl; n > 0; n -= vl, a += vl, b += vl, c += vl) {
        vl = __riscv_vsetvl_e32m8(n);
        __riscv_vse32_v_i32m8(c, __riscv_vadd_vv_i32m8(__riscv_vle32_v_i32m8(a, vl),
                                                     __riscv_vle32_v_i32m8(b, vl), vl), vl);
    }
}
static void saxpy_s(i32 *y, const i32 *x, int n){ for (int i = 0; i < n; i++) y[i] = 3 * x[i] + y[i]; }
static void saxpy_v(i32 *y, const i32 *x, int n){
    for (size_t vl; n > 0; n -= vl, x += vl, y += vl) {
        vl = __riscv_vsetvl_e32m8(n);
        vint32m8_t vy = __riscv_vle32_v_i32m8(y, vl);
        __riscv_vse32_v_i32m8(y, __riscv_vmacc_vx_i32m8(vy, 3, __riscv_vle32_v_i32m8(x, vl), vl), vl);
    }
}
static i32 dot_s(const i32 *a, const i32 *b, int n){ i32 s = 0; for (int i = 0; i < n; i++) s += a[i] * b[i]; return s; }
/* GCC 13.2 rejects the reduction intrinsics when ELEN = 32 (zve32x/f;
 * zve64x and V accept them), so the vector dot product is assembly. */
i32 dot_v(const i32 *a, const i32 *b, int n);
__asm__(
    "    .text\n"
    "    .globl dot_v\n"
    "dot_v:\n"
    "    vsetivli zero, 1, e32, m1, ta, ma\n"
    "    vmv.s.x  v24, zero\n"               /* v24[0] = running sum      */
    "1:  vsetvli  t0, a2, e32, m8, ta, ma\n"
    "    vle32.v  v8, (a0)\n"
    "    vle32.v  v16, (a1)\n"
    "    vmul.vv  v8, v8, v16\n"
    "    vredsum.vs v24, v8, v24\n"
    "    slli     t1, t0, 2\n"
    "    add      a0, a0, t1\n"
    "    add      a1, a1, t1\n"
    "    sub      a2, a2, t0\n"
    "    bnez     a2, 1b\n"
    "    vmv.x.s  a0, v24\n"
    "    ret\n");
static void copy_s(unsigned char *d, const unsigned char *s, int n){ for (int i = 0; i < n; i++) d[i] = s[i]; }
static void copy_v(unsigned char *d, const unsigned char *s, int n){
    for (size_t vl; n > 0; n -= vl, s += vl, d += vl) {
        vl = __riscv_vsetvl_e8m8(n);
        __riscv_vse8_v_u8m8(d, __riscv_vle8_v_u8m8(s, vl), vl);
    }
}

static int fails;
static void report(const char *name, unsigned ts, unsigned tv, int ok){
    kprintf("%s scalar %5u  vector %5u  speedup %u.%02ux  %s\n", name, ts, tv,
            ts / tv, (ts * 100 / tv) % 100, ok ? "ok" : "MISMATCH");
    if (!ok) fails++;
}
static int same(const i32 *x, const i32 *y, int n){ for (int i = 0; i < n; i++) if (x[i] != y[i]) return 0; return 1; }

int main(void){
    unsigned t0, ts, tv;
    i32 r1, r2;
    __asm__ volatile ("csrs mstatus, %0" :: "r"(1u << 9));     /* mstatus.VS = Initial */

    for (int i = 0; i < N; i++) { A[i] = (i32)lcg(); B[i] = (i32)lcg(); }

    t0 = MTIME; vadd_s(C, A, B, N); ts = MTIME - t0;
    t0 = MTIME; vadd_v(D, A, B, N); tv = MTIME - t0;
    report("vadd ", ts, tv, same(C, D, N));

    for (int i = 0; i < N; i++) C[i] = D[i] = B[i];
    t0 = MTIME; saxpy_s(C, A, N); ts = MTIME - t0;
    t0 = MTIME; saxpy_v(D, A, N); tv = MTIME - t0;
    report("saxpy", ts, tv, same(C, D, N));

    t0 = MTIME; r1 = dot_s(A, B, N); ts = MTIME - t0;
    t0 = MTIME; r2 = dot_v(A, B, N); tv = MTIME - t0;
    report("dot  ", ts, tv, r1 == r2);

    t0 = MTIME; copy_s((unsigned char *)C, (unsigned char *)A, 4 * N); ts = MTIME - t0;
    t0 = MTIME; copy_v((unsigned char *)D, (unsigned char *)A, 4 * N); tv = MTIME - t0;
    report("copy ", ts, tv, same(C, D, N));

    kprintf(fails ? "VEC-BENCH: FAIL\n" : "VEC-BENCH: PASS\n");
    halt(fails);
    return 0;
}
