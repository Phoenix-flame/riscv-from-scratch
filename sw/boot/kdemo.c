/* =====================================================================
 * kdemo.c  -  what a kernel's trap handler sees on this platform
 * ---------------------------------------------------------------------
 * dtdemo (Step 49) showed a program finding the machine through its
 * device tree. This one, also entered in S-mode, exercises the three
 * things Step 50 adds underneath a kernel -- and handles each the way
 * Linux's trap code does:
 *
 *   1. ACCESS FAULTS. A load from a hole in the memory map, a store to the
 *      ROM, an AMO to a hole, a jump into a hole: each traps precisely,
 *      at the instruction, with scause 5 / 7 / 7 / 1 and the address in
 *      stval -- where before Step 50 the load read 0 and the store vanished.
 *   2. A/D BITS (Svade). It turns on Sv32 with the kernel identity-mapped
 *      and one test page whose PTE has A and D clear. The first read takes
 *      a load page fault; the handler sets A, sfence.vma's, and the load
 *      re-executes. The first write takes a store page fault for D. The
 *      second write takes none.
 *   3. EXTERNAL INTERRUPTS. It finds the PLIC in the DT, picks the S-mode
 *      context (the one whose interrupts-extended entry is <&intc 9>), and
 *      enables the UART's source there. Then it prompts "type> " and takes
 *      the line typed at it as supervisor external interrupts -- claim,
 *      drain the UART's FIFO, complete -- 4 bytes at a time plus one
 *      receive timeout for the tail.
 *
 * Nothing is hardcoded but the two test addresses (a hole, and the boot
 * ROM, which the tree does not describe): RAM, PLIC and UART come from it.
 * ===================================================================== */
#include <stdint.h>
#include "lib.h"
#include "fdt.h"
#include "sbi.h"
#include "ns16550.h"

#define csr_read(csr)      ({ uint32_t v_; __asm__ volatile("csrr %0, " #csr : "=r"(v_)); v_; })
#define csr_write(csr, v)  __asm__ volatile("csrw " #csr ", %0" :: "rK"(v))
#define csr_set(csr, v)    __asm__ volatile("csrs " #csr ", %0" :: "rK"(v))
#define csr_clear(csr, v)  __asm__ volatile("csrc " #csr ", %0" :: "rK"(v))

static int fails;
static void sbi_out(int c) { sbi_putchar(c); }
static void verdict(int c) { puts_raw(c ? "  ok\n" : "  FAIL\n"); if (!c) fails++; }
static uint32_t be32(const void *p) { return fdt32(*(const uint32_t *)p); }

/* ---- the trap handler: everything that reaches stvec ----------------- */
static volatile uint32_t last_cause, last_tval, n_traps;
static volatile uint32_t resume_pc;            /* where a fetch fault continues */
static volatile uint32_t pf_a, pf_d;           /* page faults fixed up, by bit */
static volatile uint32_t *test_pte;            /* the PTE the handler may fix */
static volatile uint32_t test_va;

static struct ns16550 uart;
static volatile uint32_t *plic_claim;          /* this context's claim/complete */
static volatile uint32_t uart_irq, n_ext, n_rx;
static char line[64];

#define PTE_V (1u << 0)
#define PTE_R (1u << 1)
#define PTE_W (1u << 2)
#define PTE_X (1u << 3)
#define PTE_A (1u << 6)
#define PTE_D (1u << 7)

static void __attribute__((interrupt("supervisor"), aligned(4))) s_trap(void)
{
    uint32_t cause = csr_read(scause), tval = csr_read(stval);
    if (cause == 0x80000009u) {                      /* supervisor external */
        uint32_t id;
        while ((id = *plic_claim) != 0) {
            if (id == uart_irq) {
                int c;
                while ((c = ns16550_getc(&uart)) >= 0)
                    if (n_rx < sizeof line - 1) line[n_rx++] = (char)c;
            }
            n_ext++;
            *plic_claim = id;                        /* complete */
        }
        return;
    }
    n_traps++;
    last_cause = cause;
    last_tval = tval;
    if ((cause == 13 || cause == 15) && test_pte && (tval & ~0xfffu) == test_va) {
        /* what Linux does for a clear A / D bit: set it, flush, retry */
        if (!(*test_pte & PTE_A)) pf_a++;
        if (cause == 15 && !(*test_pte & PTE_D)) pf_d++;
        *test_pte |= PTE_A | (cause == 15 ? PTE_D : 0);
        __asm__ volatile("sfence.vma %0, zero" :: "r"(tval) : "memory");
        return;                                      /* sepc unchanged: re-execute */
    }
    if (cause == 1) { csr_write(sepc, resume_pc); return; }
    if (cause == 5 || cause == 7) { csr_write(sepc, csr_read(sepc) + 4); return; }
    printf("kdemo: unexpected trap, scause 0x%x sepc 0x%08x stval 0x%08x\n",
           cause, csr_read(sepc), tval);
    sbi_system_reset(SBI_SRST_SHUTDOWN, SBI_SRST_REASON_FAILURE);
}

static void expect_trap(uint32_t cause, uint32_t tval, const char *what)
{
    printf("  %-34s scause %2u stval 0x%08x", what, last_cause, last_tval);
    verdict(n_traps == 1 && last_cause == cause && last_tval == tval);
    n_traps = 0; last_cause = 0; last_tval = 0;
}

/* ---- 1. access faults ------------------------------------------------ */
#define HOLE 0x40000000u            /* nothing lives here */

static void access_faults(uint32_t rom)
{
    printf("\n[access faults]\n");
    uint32_t v = 0x12345678u;
    __asm__ volatile("lw %0, 0(%1)" : "+r"(v) : "r"(HOLE) : "memory");
    expect_trap(5, HOLE, "load from a hole");
    printf("  %-34s %s\n", "... and the load wrote nothing", v == 0x12345678u ? "ok" : "FAIL");
    if (v != 0x12345678u) fails++;
    __asm__ volatile("sw zero, 0(%0)" :: "r"(rom) : "memory");
    expect_trap(7, rom, "store to the boot ROM (R-X)");
    __asm__ volatile("amoadd.w zero, zero, (%0)" :: "r"(HOLE + 8) : "memory");
    expect_trap(7, HOLE + 8, "AMO to a hole");
    __asm__ volatile("la   t0, 1f\n\t"
                     "sw   t0, 0(%0)\n\t"
                     "jalr zero, 0(%1)\n"
                     "1:" :: "r"(&resume_pc), "r"(HOLE + 0x100) : "t0", "memory");
    expect_trap(1, HOLE + 0x100, "jump into a hole");
    uint32_t w;
    __asm__ volatile("lw %0, 0(%1)" : "=r"(w) : "r"(rom) : "memory");
    (void)w;
    printf("  %-34s %s\n", "load from the ROM: no trap", n_traps == 0 ? "ok" : "FAIL");
    if (n_traps) fails++;
}

/* ---- 2. A/D bits under Sv32 ------------------------------------------ */
static uint32_t root[1024] __attribute__((aligned(4096)));
static uint32_t l0[1024]   __attribute__((aligned(4096)));
static uint32_t page[1024] __attribute__((aligned(4096)));

static uint32_t mega(uint32_t pa, uint32_t flags) { return ((pa >> 12) << 10) | flags; }

static void ad_bits(uint32_t ram_base, uint32_t uart_base, uint32_t plic_base)
{
    printf("\n[A/D bits: Svade]\n");
    const uint32_t kern = PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D;
    root[ram_base >> 22]  = mega(ram_base, kern);            /* this program, identity */
    root[uart_base >> 22] = mega(uart_base, kern & ~PTE_X);  /* devices it touches */
    root[plic_base >> 22] = mega(plic_base, kern & ~PTE_X);
    test_va = 0xC0000000u;
    root[test_va >> 22]   = (((uint32_t)l0 >> 12) << 10) | PTE_V;
    l0[0] = (((uint32_t)page >> 12) << 10) | PTE_V | PTE_R | PTE_W;   /* A = D = 0 */
    test_pte = &l0[0];
    page[0] = 0xA5A5A5A5u;

    csr_write(satp, (1u << 31) | ((uint32_t)root >> 12));
    __asm__ volatile("sfence.vma" ::: "memory");
    volatile uint32_t *va = (volatile uint32_t *)test_va;

    uint32_t r = va[0];
    printf("  read  (A clear): %u load page fault, A set,  read 0x%08x", pf_a, r);
    verdict(pf_a == 1 && pf_d == 0 && last_cause == 13 && r == 0xA5A5A5A5u);
    n_traps = 0;
    va[1] = 0x600Du;
    printf("  write (D clear): %u store page fault, D set", pf_d);
    verdict(pf_d == 1 && last_cause == 15 && page[1] == 0x600Du);
    n_traps = 0;
    va[2] = 0x700Du;
    printf("  write again:     %u faults", n_traps);
    verdict(n_traps == 0 && page[2] == 0x700Du);
    printf("  PTE now 0x%08x: V R W A D, as the handler left it", *test_pte);
    verdict((*test_pte & 0xff) == (PTE_V | PTE_R | PTE_W | PTE_A | PTE_D));
    csr_write(satp, 0);
    __asm__ volatile("sfence.vma" ::: "memory");
    test_pte = 0;
}

/* ---- 3. a line of input, by interrupt -------------------------------- */
static int find_compatible(const void *fdt, int node, const char *compat)
{
    int len;
    const char *c = fdt_getprop(fdt, node, "compatible", &len);
    if (c && fdt_stringlist_contains(c, len, compat)) return node;
    for (int s = fdt_first_subnode(fdt, node); s >= 0; s = fdt_next_subnode(fdt, s)) {
        int r = find_compatible(fdt, s, compat);
        if (r >= 0) return r;
    }
    return -1;
}

static void external_irqs(const void *fdt, int plic, uint32_t plic_base, int con)
{
    printf("\n[external interrupts: PLIC]\n");
    /* the context whose interrupts-extended entry is <&cpu-intc 9> (S external) */
    int len, ctx = -1;
    const uint8_t *ie = fdt_getprop(fdt, plic, "interrupts-extended", &len);
    for (int i = 0; ie && i < len / 8; i++)
        if (be32(ie + 8 * i + 4) == 9) ctx = i;
    uart_irq = 0;
    fdt_getprop_u32(fdt, con, "interrupts", (uint32_t *)&uart_irq);
    uint32_t ndev = 0;
    fdt_getprop_u32(fdt, plic, "riscv,ndev", &ndev);
    printf("  %s: %u sources; S-mode is context %d; %s is source %u\n",
           fdt_get_name(fdt, plic), ndev, ctx, fdt_get_name(fdt, con), uart_irq);
    if (ctx < 0 || uart_irq == 0) { fails++; return; }

    volatile uint32_t *p = (volatile uint32_t *)plic_base;
    p[uart_irq] = 1;                                       /* priority */
    p[(0x2000 + 0x80 * ctx) / 4] = 1u << uart_irq;         /* enable for our context */
    p[(0x200000 + 0x1000 * ctx) / 4] = 0;                  /* threshold */
    plic_claim = &p[(0x200004 + 0x1000 * ctx) / 4];
    ns16550_rx_irq(&uart, 4);
    csr_set(sie, 1u << 9);                                 /* SEIE */
    csr_set(sstatus, 1u << 1);                             /* SIE */

    puts_raw("type> ");
    while (!(n_rx && line[n_rx - 1] == '\r')) __asm__ volatile("wfi");
    csr_clear(sstatus, 1u << 1);
    line[n_rx - 1] = 0;
    printf("\n  got \"%s\": %u bytes in %u external interrupts", line, n_rx - 1, n_ext);
    verdict(n_ext >= 2 && n_ext < n_rx);
}

int main(uint32_t hartid, const void *fdt)
{
    lib_putc = sbi_out;
    printf("kdemo: S-mode on hart %u, dtb %p\n", hartid, fdt);
    if (fdt_check(fdt)) return 1;
    csr_write(stvec, (uint32_t)&s_trap);

    int con = fdt_resolve(fdt, fdt_getprop(fdt, fdt_path_offset(fdt, "/chosen"), "stdout-path", 0));
    int plic = find_compatible(fdt, 0, "riscv,plic0");
    int mem = fdt_path_offset(fdt, "/memory");
    if (con < 0 || plic < 0 || mem < 0) return 2;
    uart.base     = be32(fdt_getprop(fdt, con, "reg", 0));
    fdt_getprop_u32(fdt, con, "reg-shift", (uint32_t *)&uart.shift);
    fdt_getprop_u32(fdt, con, "reg-io-width", (uint32_t *)&uart.io_width);
    uint32_t plic_base = be32(fdt_getprop(fdt, plic, "reg", 0));
    uint32_t ram_base  = be32(fdt_getprop(fdt, mem, "reg", 0));
    uint32_t rom = 0x00001000u;     /* a test address, like HOLE: the ROM is not in the tree */

    access_faults(rom);
    ad_bits(ram_base, uart.base, plic_base);
    external_irqs(fdt, plic, plic_base, con);

    printf("\nkdemo: %s\n", fails ? "FAILED" : "all checks passed");
    sbi_system_reset(SBI_SRST_COLD_REBOOT, SBI_SRST_REASON_NONE);
    return fails != 0;
}
