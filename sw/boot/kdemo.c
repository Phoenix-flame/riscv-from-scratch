/* =====================================================================
 * kdemo.c  -  what a kernel's trap handler sees on this platform
 * ---------------------------------------------------------------------
 * dtdemo (Step 49) showed a program finding the machine through its
 * device tree. This one, also entered in S-mode, exercises the three
 * things Step 50 adds underneath a kernel, and the misaligned traps of
 * Step 52 -- and handles each the way Linux's trap code does:
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
 *   4. MISALIGNED ACCESSES (Step 52). A word load at buf+1, a halfword
 *      store at buf+3, ...: each traps (scause 4 / 6, stval = the address)
 *      and a trap entry that saves all 32 registers -- what a kernel's
 *      does -- lets a C handler emulate it with byte accesses and write
 *      the loaded value into rd. A misaligned AMO, LR or SC is reported,
 *      not emulated (Linux sends SIGBUS: it cannot be made atomic). A jump
 *      or branch to a target that is not 4-byte aligned traps on the jump
 *      (scause 0, stval = the target) without writing rd.
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

/* ---- 4. misaligned accesses: trap and emulate ------------------------- */
/* A kernel-style trap entry: all 32 registers in a frame on the stack, so
 * the handler can read rs2 and write rd by number. frame[2] is the sp of
 * the trapping code; the handler never writes it. */
__asm__(".text\n.align 2\n"
        "ma_trap:\n"
        "  addi sp, sp, -128\n"
        "  sw x1, 4(sp)\n  sw x3, 12(sp)\n  sw x4, 16(sp)\n  sw x5, 20(sp)\n"
        "  sw x6, 24(sp)\n  sw x7, 28(sp)\n  sw x8, 32(sp)\n  sw x9, 36(sp)\n"
        "  sw x10, 40(sp)\n sw x11, 44(sp)\n sw x12, 48(sp)\n sw x13, 52(sp)\n"
        "  sw x14, 56(sp)\n sw x15, 60(sp)\n sw x16, 64(sp)\n sw x17, 68(sp)\n"
        "  sw x18, 72(sp)\n sw x19, 76(sp)\n sw x20, 80(sp)\n sw x21, 84(sp)\n"
        "  sw x22, 88(sp)\n sw x23, 92(sp)\n sw x24, 96(sp)\n sw x25, 100(sp)\n"
        "  sw x26, 104(sp)\n sw x27, 108(sp)\n sw x28, 112(sp)\n sw x29, 116(sp)\n"
        "  sw x30, 120(sp)\n sw x31, 124(sp)\n"
        "  addi t0, sp, 128\n  sw t0, 8(sp)\n  sw zero, 0(sp)\n"
        "  mv a0, sp\n  call ma_handle\n"
        "  lw x1, 4(sp)\n  lw x3, 12(sp)\n  lw x4, 16(sp)\n  lw x5, 20(sp)\n"
        "  lw x6, 24(sp)\n  lw x7, 28(sp)\n  lw x8, 32(sp)\n  lw x9, 36(sp)\n"
        "  lw x10, 40(sp)\n lw x11, 44(sp)\n lw x12, 48(sp)\n lw x13, 52(sp)\n"
        "  lw x14, 56(sp)\n lw x15, 60(sp)\n lw x16, 64(sp)\n lw x17, 68(sp)\n"
        "  lw x18, 72(sp)\n lw x19, 76(sp)\n lw x20, 80(sp)\n lw x21, 84(sp)\n"
        "  lw x22, 88(sp)\n lw x23, 92(sp)\n lw x24, 96(sp)\n lw x25, 100(sp)\n"
        "  lw x26, 104(sp)\n lw x27, 108(sp)\n lw x28, 112(sp)\n lw x29, 116(sp)\n"
        "  lw x30, 120(sp)\n lw x31, 124(sp)\n"
        "  addi sp, sp, 128\n"
        "  sret\n");
void ma_trap(void);
void ma_handle(uint32_t *frame);

static volatile uint32_t n_emulated;

/* what Linux's handle_misaligned_load / _store do, for RV32I: decode the
 * instruction at sepc, move the bytes one at a time, step past it */
void ma_handle(uint32_t *frame)
{
    uint32_t cause = csr_read(scause), addr = csr_read(stval), pc = csr_read(sepc);
    uint32_t insn = *(volatile uint32_t *)pc;
    uint32_t op = insn & 0x7f, f3 = (insn >> 12) & 7, rd = (insn >> 7) & 31, rs2 = (insn >> 20) & 31;
    volatile uint8_t *p = (volatile uint8_t *)addr;
    n_traps++;
    last_cause = cause;
    last_tval = addr;
    if (cause == 4 && op == 0x03) {                         /* lh lw lhu */
        uint32_t n = (f3 & 3) == 1 ? 2 : 4, v = 0;
        for (uint32_t i = 0; i < n; i++) v |= (uint32_t)p[i] << (8 * i);
        if (f3 == 1) v = (uint32_t)(int32_t)(int16_t)v;     /* lh sign-extends */
        if (rd) frame[rd] = v;
        n_emulated++;
    } else if (cause == 6 && op == 0x23) {                  /* sh sw */
        uint32_t n = f3 == 1 ? 2 : 4, v = frame[rs2];
        for (uint32_t i = 0; i < n; i++) p[i] = (uint8_t)(v >> (8 * i));
        n_emulated++;
    } else if (cause != 0 && cause != 4 && cause != 6) {
        printf("kdemo: unexpected trap, scause 0x%x sepc 0x%08x stval 0x%08x\n", cause, pc, addr);
        sbi_system_reset(SBI_SRST_SHUTDOWN, SBI_SRST_REASON_FAILURE);
    }
    /* an AMO / LR / SC is not emulated (Linux: SIGBUS), nor is a jump to a
     * bad target -- the test just steps over the instruction */
    csr_write(sepc, pc + 4);
}

static uint8_t buf[16] __attribute__((aligned(4)));

static void reset_buf(void) { for (int i = 0; i < 16; i++) buf[i] = (uint8_t)(0x10 + i); }

/* one trap at buf+off with this cause, and (for an emulated access) the value */
static void expect_ma(uint32_t cause, uint32_t off, int emulated, int ok, const char *what)
{
    printf("  %-28s scause %u stval buf+%u", what, last_cause, last_tval - (uint32_t)buf);
    verdict(n_traps == 1 && last_cause == cause && last_tval == (uint32_t)buf + off &&
            n_emulated == (uint32_t)emulated && ok);
    n_traps = 0; n_emulated = 0; last_cause = 0; last_tval = 0;
}

static void misaligned(void)
{
    printf("\n[misaligned: trap and emulate]\n");
    csr_write(stvec, (uint32_t)&ma_trap);
    uint8_t *b = buf;
    uint32_t v;

    reset_buf();
    __asm__ volatile("lw %0, 1(%1)" : "=r"(v) : "r"(b) : "memory");
    expect_ma(4, 1, 1, v == 0x14131211u, "lw  at buf+1 -> 0x14131211");
    __asm__ volatile("lw %0, 3(%1)" : "=r"(v) : "r"(b) : "memory");
    expect_ma(4, 3, 1, v == 0x16151413u, "lw  at buf+3 -> 0x16151413");
    buf[6] = 0x80;
    __asm__ volatile("lh %0, 5(%1)" : "=r"(v) : "r"(b) : "memory");
    expect_ma(4, 5, 1, v == 0xffff8015u, "lh  at buf+5 -> 0xffff8015");
    __asm__ volatile("lhu %0, 5(%1)" : "=r"(v) : "r"(b) : "memory");
    expect_ma(4, 5, 1, v == 0x00008015u, "lhu at buf+5 -> 0x00008015");

    reset_buf();
    __asm__ volatile("sw %0, 2(%1)" :: "r"(0xa1b2c3d4u), "r"(b) : "memory");
    expect_ma(6, 2, 1, buf[1] == 0x11 && buf[2] == 0xd4 && buf[3] == 0xc3 &&
                       buf[4] == 0xb2 && buf[5] == 0xa1 && buf[6] == 0x16,
              "sw  at buf+2, bytes ok");
    __asm__ volatile("sh %0, 7(%1)" :: "r"(0xbeefu), "r"(b) : "memory");
    expect_ma(6, 7, 1, buf[6] == 0x16 && buf[7] == 0xef && buf[8] == 0xbe && buf[9] == 0x19,
              "sh  at buf+7, bytes ok");

    /* atomics: trap, not emulated -- and memory is untouched */
    reset_buf();
    __asm__ volatile("amoadd.w %0, %2, (%1)" : "=r"(v) : "r"(b + 2), "r"(1) : "memory");
    expect_ma(6, 2, 0, buf[2] == 0x12 && buf[5] == 0x15, "amoadd.w at buf+2");
    __asm__ volatile("lr.w %0, (%1)" : "=r"(v) : "r"(b + 1) : "memory");
    expect_ma(4, 1, 0, 1, "lr.w at buf+1");
    v = 7;
    __asm__ volatile("sc.w %0, %2, (%1)" : "+r"(v) : "r"(b + 3), "r"(0) : "memory");
    expect_ma(6, 3, 0, v == 7 && buf[3] == 0x13, "sc.w at buf+3, rd kept");

    /* a jump / branch to a target that is not 4-byte aligned */
    uint32_t target, rd = 0x5a5a5a5au;
    __asm__ volatile("la   t0, 1f\n\t"
                     "addi %1, t0, 2\n\t"
                     "jalr %0, 2(t0)\n"
                     "1:  nop" : "+r"(rd), "=&r"(target) :: "t0", "memory");
    printf("  %-28s scause %u stval %s", "jalr to 1f+2, rd kept", last_cause,
           last_tval == target ? "= target" : "!= target");
    verdict(n_traps == 1 && last_cause == 0 && last_tval == target && rd == 0x5a5a5a5au);
    n_traps = 0;
    __asm__ volatile("la   %0, 1f + 2\n\t"
                     "beq  zero, zero, 1f + 2\n"
                     "1:  nop\n\t"
                     "nop" : "=&r"(target) :: "memory");
    printf("  %-28s scause %u stval %s", "beq to 1f+2", last_cause,
           last_tval == target ? "= target" : "!= target");
    verdict(n_traps == 1 && last_cause == 0 && last_tval == target);
    n_traps = 0;

    /* aligned, and a byte anywhere: no trap */
    reset_buf();
    __asm__ volatile("lw  %0, 4(%1)\n\t"
                     "lhu t0, 6(%1)\n\t"
                     "lbu t0, 7(%1)\n\t"
                     "sb  t0, 9(%1)" : "=r"(v) : "r"(b) : "t0", "memory");
    printf("  %-28s no trap", "aligned lw/lhu, any lbu/sb");
    verdict(n_traps == 0 && v == 0x17161514u);
    csr_write(stvec, (uint32_t)&s_trap);
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
    /* how many depends on how fast the handler gets there (cold caches:
       fewer, longer ones); what matters is that it is not one per byte */
    printf("\n  got \"%s\": %u bytes in %u external interrupts", line, n_rx - 1, n_ext);
    verdict(n_ext >= 1 && n_ext < n_rx - 1);
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
    misaligned();
    ad_bits(ram_base, uart.base, plic_base);
    external_irqs(fdt, plic, plic_base, con);

    printf("\nkdemo: %s\n", fails ? "FAILED" : "all checks passed");
    sbi_system_reset(SBI_SRST_COLD_REBOOT, SBI_SRST_REASON_NONE);
    return fails != 0;
}
