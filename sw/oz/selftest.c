/* selftest.c - the OpenZynq RISC-V self-test (Step 45).
 *
 * Built by tools/rvgen for exactly the configuration in .config: the
 * generated oz_config.h says which features exist, -march matches the core,
 * and only the checks for features that are present are compiled in. It
 * prints the configuration, runs every check, prints "ALL PASS" (or what
 * failed) and returns the number of failures, which start.S writes to
 * SYSCON -- that halts the core, and the exit code is what the PS app (or
 * the testbench) reports.
 *
 * Memory map: see rtl/oz/oz_rv_soc.v. */
#include "oz_config.h"
#include "firmware.h"

#define CSRR(r)      ({ unsigned _v; asm volatile ("csrr %0, " #r : "=r"(_v)); _v; })
#define CSRW(r, v)   asm volatile ("csrw " #r ", %0" :: "r"((unsigned)(v)))
#define CSRS(r, v)   asm volatile ("csrs " #r ", %0" :: "r"((unsigned)(v)))
#define CSRC(r, v)   asm volatile ("csrc " #r ", %0" :: "r"((unsigned)(v)))

#define MTIME     (*(volatile unsigned *)0x10010000u)
#define MTIMECMP  (*(volatile unsigned *)0x10010004u)
#define GPIO_OUT  (*(volatile unsigned *)0x10020000u)
#define GPIO_IN   (*(volatile unsigned *)0x10020004u)

/* ---- shared with start.S ---- */
unsigned          oz_ctx[14];
volatile unsigned oz_lower_active, oz_s_hits, oz_s_cause;
extern unsigned   oz_enter_lower(void (*fn)(void), unsigned mode);
extern void       oz_s_trap(void);

static volatile unsigned ticks, bad_cause, bad_tval;
static int passes, fails;

/* C half of the M-mode trap vector. Nonzero = abort the lower-mode run. */
int oz_trap(void)
{
    unsigned cause = CSRR(mcause);
    if (cause == 0x80000007u) {               /* timer: count it, disarm */
        MTIMECMP = 0xFFFFFFFFu;
        ticks++;
        return 0;
    }
    bad_cause = cause;
    bad_tval  = CSRR(mtval);
    if (oz_lower_active) return 1;            /* the U/S test faulted: back to M */
    CSRW(mepc, CSRR(mepc) + 4);               /* unexpected in M: skip it */
    return 0;
}

static void check(const char *what, int ok)
{
    kprintf("  [%s] %s\n", ok ? "pass" : "FAIL", what);
    if (ok) passes++; else fails++;
}

#if CONFIG_ISA_V
/* c[i] = a[i] * b[i] + a[i], strip-mined at LMUL = 2; returns the sum of c
 * (vredsum). Assembly: GCC 13 has no reduction intrinsics for ELEN = 32. */
unsigned oz_vtest(const unsigned *a, const unsigned *b, unsigned *c, unsigned n);
asm("    .text\n"
    "    .globl oz_vtest\n"
    "oz_vtest:\n"
    "    vsetivli zero, 1, e32, m1, ta, ma\n"
    "    vmv.s.x  v8, zero\n"
    "1:  vsetvli  t0, a3, e32, m2, ta, ma\n"
    "    vle32.v  v2, (a0)\n"
    "    vle32.v  v4, (a1)\n"
    "    vmadd.vv v4, v2, v2\n"               /* v4 = v4 * v2 + v2 */
    "    vse32.v  v4, (a2)\n"
    "    vredsum.vs v8, v4, v8\n"
    "    slli     t1, t0, 2\n"
    "    add      a0, a0, t1\n"
    "    add      a1, a1, t1\n"
    "    add      a2, a2, t1\n"
    "    sub      a3, a3, t0\n"
    "    bnez     a3, 1b\n"
    "    vmv.x.s  a0, v8\n"
    "    ret\n");
#endif

#if CONFIG_PRIV_U
static void u_ecall(void)  { asm volatile ("ecall"); for (;;) { } }
static void u_csr(void)    { (void)CSRR(mstatus); asm volatile ("ecall"); for (;;) { } }
#endif

#if CONFIG_MMU
/* identity 4 MiB superpage for code/data/stack (U may use it), plus VA
 * 0x00400000 -> alias_page through a level-0 table; 0x00800000 unmapped */
static unsigned root[1024]      __attribute__((aligned(4096)));
static unsigned l0[1024]        __attribute__((aligned(4096)));
static unsigned alias_page[1024] __attribute__((aligned(4096)));
#define VA_ALIAS 0x00400000u
static void u_mmu_alias(void)
{
    volatile unsigned *a = (volatile unsigned *)(VA_ALIAS + 16);
    *a = 0xC0FFEE00u | (*a & 0xFFu);
    asm volatile ("ecall");
    for (;;) { }
}
static void u_mmu_unmapped(void)
{
    (void)*(volatile unsigned *)0x00800000u;  /* load page fault */
    asm volatile ("ecall");
    for (;;) { }
}
#endif

int main(void)
{
    kprintf("\nOpenZynq RISC-V self-test\n");
    kprintf("  config : %s\n", CONFIG_OZ_SUMMARY);
    kprintf("  memory : IMEM %d KiB, DMEM %d KiB\n", CONFIG_IMEM_KB, CONFIG_DMEM_KB);

    /* ---- base ISA ---- */
    {
        volatile unsigned a = 0x12345678u, b = 5;
        unsigned s = 0, i;
        for (i = 1; i <= 100; i++) s += i;
        check("RV32I: loop, shifts, compares",
              s == 5050 && (a >> b) == 0x0091A2B3u && (int)(a << 3) < 0 && (a ^ 0xFFu) == 0x12345687u);
    }

#if CONFIG_ISA_M
    {
        volatile int x = -123457, y = 789;
        volatile unsigned ux = 0xDEADBEEFu, uy = 0x10001u;
        check("M: mul / mulh / div / rem",
              x * y == -97407573 &&
              (int)(((long long)x * y) >> 32) == -1 &&
              (unsigned)(((unsigned long long)ux * uy) >> 32) == 0xDEAEu &&
              x / y == -156 && x % y == -373 && ux / uy == 0xDEACu && ux % uy == 0xE043u);
    }
#endif

    /* ---- a feature that is configured OFF must really be absent ---- */
#if !CONFIG_ISA_M && CONFIG_CORE_PIPE
    bad_cause = 0;
    asm volatile (".word 0x02b50533" ::: "a0");           /* mul a0, a0, a1 */
    check("M absent: mul is an illegal instruction", bad_cause == 2);
#endif
#if !CONFIG_ISA_A
    {
        volatile unsigned scratch = 0;
        bad_cause = 0;
        asm volatile ("mv a0, %0\n.word 0x00b5202f" :: "r"(&scratch) : "a0", "memory"); /* amoadd.w */
        check("A absent: amoadd is an illegal instruction", bad_cause == 2 && scratch == 0);
    }
#endif
#if !CONFIG_PRIV_U && CONFIG_CORE_PIPE
    {
        unsigned ms = CSRR(mstatus);
        CSRW(mstatus, ms & ~(3u << 11));                  /* try MPP = U */
        check("U absent: mstatus.MPP cannot hold U", ((CSRR(mstatus) >> 11) & 3u) == 3u);
        CSRW(mstatus, ms);
    }
#endif

#if CONFIG_ISA_A
    {
        volatile unsigned v = 40, old, r, sc;
        asm volatile ("amoadd.w %0, %2, (%1)" : "=r"(old) : "r"(&v), "r"(2u) : "memory");
        asm volatile ("lr.w %0, (%1)" : "=r"(r) : "r"(&v) : "memory");
        asm volatile ("sc.w %0, %2, (%1)" : "=r"(sc) : "r"(&v), "r"(r + 1) : "memory");
        check("A: amoadd / lr / sc", old == 40 && r == 42 && sc == 0 && v == 43);
    }
#endif

#if CONFIG_ISA_ZBA
    {
        unsigned r1, r2;
        asm volatile ("sh2add %0, %1, %2" : "=r"(r1) : "r"(0x10u), "r"(0x100u));
        asm volatile ("sh3add %0, %1, %2" : "=r"(r2) : "r"(3u), "r"(1u));
        check("Zba: sh2add / sh3add", r1 == 0x140u && r2 == 25u);
    }
#endif

#if CONFIG_ISA_ZBB
    {
        unsigned x = 0x00F0F000u, r1, r2, r3, r4, r5, r6, r7;
        asm volatile ("clz  %0, %1" : "=r"(r1) : "r"(x));
        asm volatile ("ctz  %0, %1" : "=r"(r2) : "r"(x));
        asm volatile ("cpop %0, %1" : "=r"(r3) : "r"(x));
        asm volatile ("rev8 %0, %1" : "=r"(r4) : "r"(0x11223344u));
        asm volatile ("andn %0, %1, %2" : "=r"(r5) : "r"(0xFFu), "r"(0x0Fu));
        asm volatile ("max  %0, %1, %2" : "=r"(r6) : "r"(-5), "r"(3));
        asm volatile ("rori %0, %1, 8"  : "=r"(r7) : "r"(0x11223344u));
        check("Zbb: clz / ctz / cpop / rev8 / andn / max / rori",
              r1 == 8 && r2 == 12 && r3 == 8 && r4 == 0x44332211u && r5 == 0xF0u &&
              r6 == 3 && r7 == 0x44112233u);
    }
#elif CONFIG_CORE_PIPE
    bad_cause = 0;
    asm volatile (".word 0x40b57533" ::: "a0");           /* andn a0, a0, a1 */
    check("Zbb absent: andn is an illegal instruction", bad_cause == 2);
#endif

#if CONFIG_ISA_ZBC
    {
        unsigned r1, r2;
        asm volatile ("clmul  %0, %1, %2" : "=r"(r1) : "r"(5u), "r"(3u));
        asm volatile ("clmulh %0, %1, %2" : "=r"(r2) : "r"(0x80000000u), "r"(2u));
        check("Zbc: clmul / clmulh", r1 == 0xFu && r2 == 1u);
    }
#endif

#if CONFIG_ISA_ZBS
    {
        unsigned r1, r2, r3;
        asm volatile ("bset  %0, %1, %2" : "=r"(r1) : "r"(0u), "r"(5u));
        asm volatile ("bexti %0, %1, 5"  : "=r"(r2) : "r"(0x20u));
        asm volatile ("binvi %0, %1, 0"  : "=r"(r3) : "r"(0xFFu));
        check("Zbs: bset / bexti / binvi", r1 == 32u && r2 == 1u && r3 == 0xFEu);
    }
#endif

    /* vsetvli zero, zero, e8, m1, ta, ma -- as a .word so it assembles without V */
#define VSETVLI_ZERO ".word 0x0c007057"
#if CONFIG_ISA_V
    {
        unsigned a[37], b[37], c[37], sum = 0, ok = 1, n;
        CSRC(mstatus, 3u << 9);
        bad_cause = 0;
        asm volatile (VSETVLI_ZERO);
        check("V: illegal while mstatus.VS = Off", bad_cause == 2);
        CSRS(mstatus, 1u << 9);                          /* VS = Initial */
        for (n = 0; n < 37; n++) { a[n] = n * 0x01010101u + 7; b[n] = 3 * n + 1; }
        unsigned got = oz_vtest(a, b, c, 37);
        for (n = 0; n < 37; n++) { sum += a[n] * b[n] + a[n]; ok &= c[n] == a[n] * b[n] + a[n]; }
        check("V: vle32 / vmadd / vse32 / vredsum, 37 elements", ok && got == sum);
        bad_cause = 0;
        asm volatile (".word 0xc2001073");               /* csrw vl, zero: vl is read-only */
        check("V: writing the read-only vl CSR is illegal", bad_cause == 2);
        check("V: vlenb = VLEN / 8, mstatus.VS = Dirty, SD = 1",
              CSRR(vlenb) == CONFIG_OZ_VLEN / 8 && ((CSRR(mstatus) >> 9) & 3u) == 3u &&
              (CSRR(mstatus) >> 31) == 1u);
    }
#elif CONFIG_CORE_PIPE
    CSRS(mstatus, 3u << 9);
    bad_cause = 0;
    asm volatile (VSETVLI_ZERO);
    check("V absent: mstatus.VS reads 0, vsetvli is illegal",
          ((CSRR(mstatus) >> 9) & 3u) == 0u && bad_cause == 2);
#endif

#if CONFIG_ISA_ZICNTR
    {   /* Step 48: instret is exact, cycle counts, the user alias is
         * read-only (numeric CSR names: -march does not list Zicntr) */
        unsigned i0, i1, c0, c1;
        asm volatile ("csrr %0, 0xC02; nop; nop; nop; csrr %1, 0xC02" : "=r"(i0), "=r"(i1));
        asm volatile ("csrr %0, 0xC00; csrr %1, 0xC00" : "=r"(c0), "=r"(c1));
        bad_cause = 0;
        asm volatile ("csrw 0xC00, zero");
        check("Zicntr: instret exact, cycle counts, cycle is read-only",
              i1 - i0 == 4 && c1 != c0 && bad_cause == 2);
    }
#elif CONFIG_CORE_PIPE
    {
        unsigned c;
        asm volatile ("csrr %0, 0xC00" : "=r"(c));
        check("Zicntr absent: cycle reads 0", c == 0);
    }
#endif

#if CONFIG_ISA_C
    {   /* the image itself is compressed: look for 16-bit encodings in main
         * (the data memory holds a copy of the program image) */
        const unsigned short *p = (const unsigned short *)(unsigned)&main;
        int i, n16 = 0;
        for (i = 0; i < 64; i++) if ((p[i] & 3u) != 3u) n16++;
        check("C: program runs as compressed code", n16 > 8);
    }
#endif

#if CONFIG_ISA_F
    {
        volatile float a = 1.5f, b = 2.25f, c = 10.0f, d = 4.0f, e = 3.75f;
        check("F: fmul / fdiv / fsqrt / fcvt",
              a * b == 3.375f && c / d == 2.5f && __builtin_sqrtf(b) == 1.5f &&
              (int)e == 3 && (float)(int)c == 10.0f);
    }
#endif

#if CONFIG_TIMER
    {
        unsigned t0 = MTIME, spin = 0;
        ticks = 0;
        MTIMECMP = MTIME + 2000u;
        CSRS(mie, 1u << 7);                   /* MTIE */
        CSRS(mstatus, 1u << 3);               /* MIE  */
        while (ticks == 0 && ++spin < 200000u) { }
        CSRC(mstatus, 1u << 3);
        CSRC(mie, 1u << 7);
        check("timer: mtime counts, interrupt fires", MTIME != t0 && ticks == 1);
    }
#endif

#if CONFIG_PRIV_U
    check("U-mode: ecall from U reaches M (cause 8)", oz_enter_lower(u_ecall, 0) == 8);
    bad_cause = 0;
    check("U-mode: CSR access from U is illegal (cause 2)",
          oz_enter_lower(u_csr, 0) == 2 && bad_cause == 2);
#endif

#if CONFIG_PRIV_S
    {
        unsigned c;
        oz_s_hits = 0; oz_s_cause = 0;
        CSRW(stvec, (unsigned)&oz_s_trap);
        CSRW(medeleg, 1u << 8);               /* U ecall -> S */
        c = oz_enter_lower(u_ecall, 0);       /* S handler then ecalls M */
        CSRW(medeleg, 0);
        check("S-mode: delegated U ecall handled in S, S ecall reaches M",
              c == 9 && oz_s_hits == 1 && oz_s_cause == 8);
    }
#endif

#if CONFIG_MMU
    {
        unsigned c1, c2;
        root[0] = (0u << 20) | 0x1F;                              /* V R W X U, 4 MiB */
        root[1] = (((unsigned)l0 >> 12) << 10) | 1u;              /* -> level 0 */
        l0[0]   = (((unsigned)alias_page >> 12) << 10) | 0x17u;   /* V R W U */
        alias_page[4] = 0x5Au;
        CSRW(satp, 0x80000000u | ((unsigned)root >> 12));
        asm volatile ("sfence.vma" ::: "memory");
        c1 = oz_enter_lower(u_mmu_alias, 0);
        bad_cause = 0; bad_tval = 0;
        c2 = oz_enter_lower(u_mmu_unmapped, 0);
        CSRW(satp, 0);
        asm volatile ("sfence.vma" ::: "memory");
        check("MMU: U store through a remapped VA lands in its physical page",
              c1 == 8 && alias_page[4] == 0xC0FFEE5Au);
        check("MMU: unmapped VA is a load page fault, mtval = the VA",
              c2 == 13 && bad_tval == 0x00800000u);
    }
#endif

#if CONFIG_GPIO
    GPIO_OUT = 2;
    check("GPIO: LED register reads back", (GPIO_OUT & 3u) == 2u && (GPIO_IN & ~3u) == 0);
#endif

    kprintf("  %d/%d checks passed\n", passes, passes + fails);
    if (fails == 0) kprintf("ALL PASS\n");
    else            kprintf("FAILED: %d\n", fails);
#if CONFIG_GPIO
    GPIO_OUT = fails ? 1u : 3u;               /* both LEDs on = pass */
#endif
    return fails;
}
