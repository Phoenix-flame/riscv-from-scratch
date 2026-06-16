/* =====================================================================
 * fp_demo.c  -  Exercises the single-precision F extension end to end.
 * ---------------------------------------------------------------------
 * Compiled -march=rv32imf -mabi=ilp32f, so gcc emits real hardware float
 * instructions (flw/fsw, fadd.s/fsub.s/fmul.s/fdiv.s, fsqrt.s, fcvt, fmv,
 * compares). Each result is stored to a fixed RAM address as raw 32-bit
 * float bits (via fsw) or as an integer; the testbench checks them against
 * values computed by the host. A sentinel 0x600D marks completion.
 * ===================================================================== */
#define FR(i)  (*(volatile float    *)(0x600 + (i)*4))
#define IR(i)  (*(volatile unsigned *)(0x600 + (i)*4))
#define SENT   (*(volatile unsigned *)(0x6F0))
#define SYSCON (*(volatile unsigned *)(0x20000000))

int main(void)
{
    volatile float a = 3.5f, b = 2.25f, c = 1.5f, d = 7.0f;

    FR(0) = a + b;                 /* 5.75   */
    FR(1) = 10.0f - 7.5f;          /* 2.5    */
    FR(2) = c * 2.5f;              /* 3.75   */
    FR(3) = d / 2.0f;              /* 3.5    */
    FR(4) = __builtin_sqrtf(2.0f); /* 1.41421356... */
    FR(5) = (float)42;             /* fcvt.s.w */
    FR(6) = __builtin_sqrtf(16.0f);/* 4.0    */
    FR(7) = 0.1f + 0.2f;           /* 0.30000001... (classic) */
    FR(8) = 3.14159f * 2.0f;       /* 6.28318  */
    FR(9) = -a * b;                /* -7.875  */

    IR(10) = (unsigned)(int)3.9f;            /* fcvt.w.s truncates -> 3 */
    IR(11) = (c < 2.5f) ? 1u : 0u;           /* flt.s -> 1 */
    IR(12) = (a == 3.5f) ? 1u : 0u;          /* feq.s -> 1 */

    float r = 1.0f / 3.0f;
    FR(13) = r * 3.0f;             /* ~1.0 (rounding) */
    FR(14) = a > b ? a : b;        /* fmax-ish via compare -> 3.5 */

    SENT = 0x600D;
    SYSCON = 1;
    for (;;) { }
    return 0;
}
