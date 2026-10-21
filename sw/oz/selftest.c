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
