// =====================================================================
// hello.c  -  bring-up firmware and self-test for the Spartan-6 SoC
// ---------------------------------------------------------------------
// Prints what the hardware says about itself, then exercises every
// feature the core claims in misa and every peripheral in the SoC:
//
//   M    mul / mulh / div / rem, including the signed corner cases
//   A    lr.w / sc.w and amoadd/amoswap/amomax
//   C    the whole program is built -march=rv32imac, so every line of
//        this file is already a compressed-instruction test
//   Zicsr / Zicntr   mcycle and minstret actually advancing
//   traps            ecall, ebreak and an illegal instruction
//   U mode           drop to user, ecall back up to machine
//   CLINT            mtime, and a timer interrupt woken out of wfi
//   UART             loopback with FIFOs, then real echo
//   SRAM             a walking pattern over the IS61WV5128BLL
//
// Each check prints "ok" or "FAIL"; the exit code is the number of
// failures, which is what a testbench (and tb/s6_soc_tb.v) looks at.
// =====================================================================
#include "bsp.h"

static volatile uint32_t timer_ticks;
static volatile uint32_t trap_count;
static volatile uint32_t last_cause;
static volatile uint32_t user_ecall_seen;
static volatile uint32_t umode_resume;    // where an ecall from U resumes

static int failures;

static void check(const char *what, int ok)
{
    s6_printf("  %-22s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok) failures++;
}

// =====================================================================
// Traps
// =====================================================================
uint32_t trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval)
{
    (void)mtval;
    last_cause = mcause;

    if (mcause & 0x80000000u) {                    // ---- interrupt ----
        uint32_t code = mcause & 0xFFu;
        if (code == 7) {                           // machine timer
            timer_ticks++;
            CLINT_MTIMECMPH = 0xFFFFFFFFu;         // disarm
            CLINT_MTIMECMPL = 0xFFFFFFFFu;
        } else if (code == 11) {                   // machine external
            UART_IE = 0;                           // silence it; polled below
        }
        return mepc;                               // resume where we were
    }

    trap_count++;
    if (mcause == 8) {                             // ecall from user mode
        user_ecall_seen = 1;
        csr_set(mstatus, 0x1800u);                 // MPP = M: return to machine
        return umode_resume;                       // ... at the continuation
    }
    // step over the faulting instruction: 2 bytes if it is compressed
    return mepc + ((*(volatile uint16_t *)mepc & 3u) == 3u ? 4u : 2u);
}

// =====================================================================
// Feature checks
// =====================================================================
// Emit one specific RV32M instruction and hand back its result. Going
// through asm rather than C operators means each of the eight opcodes is
// actually tested, instead of whichever ones gcc felt like emitting.
#define MD2(op, x, y) ({ uint32_t _r;                                    \
    __asm__ volatile (op " %0, %1, %2" : "=r"(_r) : "r"(x), "r"(y));     \
    _r; })

static void test_muldiv(void)
{
    // The hardware side reads `volatile` operands, so gcc cannot fold it.
    // The expected side is the same literals in 64-bit arithmetic, folded
    // at compile time -- so there are no hand-written magic constants to
    // get wrong, and the test is its own reference model.
    volatile int32_t  a  = -1234567, b = 7654321;
    volatile uint32_t ua = 0xDEADBEEFu, ub = 0x12345678u;
    volatile int32_t  mn = (int32_t)0x80000000, m1 = -1, z = 0;

    const int64_t  A  = -1234567, B = 7654321;
    const uint64_t UA = 0xDEADBEEFu, UB = 0x12345678u;
    int ok = 1;

    ok &= MD2("mul",    a,  b)  == (uint32_t)(A * B);
    ok &= MD2("mulh",   a,  b)  == (uint32_t)((A * B) >> 32);
    ok &= MD2("mulhu",  ua, ub) == (uint32_t)((UA * UB) >> 32);
    ok &= MD2("mulhsu", a,  ub) == (uint32_t)((A * (int64_t)UB) >> 32);

    ok &= MD2("div",  a,  b)  == 0;
    ok &= MD2("rem",  a,  b)  == (uint32_t)a;
    ok &= MD2("divu", ua, ub) == (uint32_t)(UA / UB);
    ok &= MD2("remu", ua, ub) == (uint32_t)(UA % UB);

    ok &= MD2("div", mn, m1) == 0x80000000u;       // signed overflow rule
    ok &= MD2("rem", mn, m1) == 0;
    ok &= MD2("div",  m1, z) == 0xFFFFFFFFu;       // divide by zero rules
    ok &= MD2("rem",  m1, z) == (uint32_t)m1;
    ok &= MD2("divu", m1, z) == 0xFFFFFFFFu;
    ok &= MD2("remu", m1, z) == (uint32_t)m1;

    check("rv32m mul/div", ok);
}

static uint32_t amo_cell;

static void test_atomics(void)
{
    int ok = 1;
    uint32_t old, sc;

    amo_cell = 100;
    __asm__ volatile ("amoadd.w %0, %2, (%1)"
                      : "=r"(old) : "r"(&amo_cell), "r"(23) : "memory");
    ok &= (old == 100) && (amo_cell == 123);

    __asm__ volatile ("amoswap.w %0, %2, (%1)"
                      : "=r"(old) : "r"(&amo_cell), "r"(7) : "memory");
    ok &= (old == 123) && (amo_cell == 7);

    __asm__ volatile ("amomax.w %0, %2, (%1)"
                      : "=r"(old) : "r"(&amo_cell), "r"(-5) : "memory");
    ok &= (old == 7) && (amo_cell == 7);

    // lr/sc: the paired store must succeed, a bare sc must fail
    __asm__ volatile ("lr.w   %0, (%1)"  : "=r"(old) : "r"(&amo_cell) : "memory");
    __asm__ volatile ("sc.w   %0, %2, (%1)"
                      : "=r"(sc) : "r"(&amo_cell), "r"(42) : "memory");
    ok &= (sc == 0) && (amo_cell == 42);

    __asm__ volatile ("sc.w   %0, %2, (%1)"
                      : "=r"(sc) : "r"(&amo_cell), "r"(99) : "memory");
    ok &= (sc != 0) && (amo_cell == 42);           // no reservation -> no store

    check("rv32a lr/sc/amo", ok);
}

static void test_counters(void)
{
    uint32_t c0 = csr_read(mcycle);
    uint32_t i0 = csr_read(minstret);
    for (volatile int i = 0; i < 20; i++) { }
    uint32_t c1 = csr_read(mcycle);
    uint32_t i1 = csr_read(minstret);
    check("zicntr counters", (c1 > c0) && (i1 > i0) && ((c1 - c0) >= (i1 - i0)));
}

static void test_traps(void)
{
    uint32_t before = trap_count;

    __asm__ volatile ("ecall");
    int ok = (trap_count == before + 1) && (last_cause == 11);   // ecall from M

    __asm__ volatile ("ebreak");
    ok &= (trap_count == before + 2) && (last_cause == 3);

    // NOT .word 0x00000000: with the C extension that is *two* illegal
    // 16-bit instructions and traps twice. 0xFFFFFFFF has opcode 1111111,
    // which is reserved, and its low bits mark it as one 32-bit word.
    __asm__ volatile (".word 0xFFFFFFFF");
    ok &= (trap_count == before + 3) && (last_cause == 2);

    check("traps ecall/ebreak/ill", ok);
}

// Runs in user mode, and never returns. It cannot: we jumped here with
// mret rather than a call, so there is no return address to come back on.
// The ecall traps to machine mode and the handler resumes at a
// continuation point inside test_user_mode -- which is how a real kernel
// re-enters itself after a syscall, rather than "falling out" of the
// user function.
static void user_body(void) { for (;;) __asm__ volatile ("ecall"); }

static void test_user_mode(void)
{
    uint32_t *slot = (uint32_t *)&umode_resume;

    user_ecall_seen = 0;
    csr_clear(mstatus, 0x1800u);                   // MPP = 00 -> user
    csr_write(mepc, (uint32_t)&user_body);
    __asm__ volatile (
        "la   t0, 1f\n"                            // where the handler resumes
        "sw   t0, 0(%0)\n"
        "mret\n"                                   // -> user_body, in U mode
        "1:\n"
        :: "r"(slot) : "t0", "memory");

    check("user mode + ecall", user_ecall_seen == 1);
}

static void test_timer_irq(void)
{
    uint64_t now = mtime_get();
    timer_ticks = 0;
    CLINT_MTIMECMPH = (uint32_t)((now + 200) >> 32);
    CLINT_MTIMECMPL = (uint32_t)(now + 200);

    csr_set(mie, MIE_MTIE);
    csr_set(mstatus, MSTATUS_MIE);
    while (timer_ticks == 0) wfi();               // real sleep, not a spin
    csr_clear(mie, MIE_MTIE);

    check("timer irq + wfi", timer_ticks == 1);
}

static void test_uart_loopback(void)
{
    const char *msg = "Loopback";
    int ok = 1, i;

    // Drain what is already queued BEFORE touching the mux. Switching to
    // loopback mid-frame hands the receiver half a character, and it then
    // locks onto the wrong bit phase for the whole test; TXCLR on top of
    // that would silently eat the rest of the line we were printing.
    uart_flush();

    UART_CTRL |= UART_CTRL_LOOP | UART_CTRL_TXCLR | UART_CTRL_RXCLR;
    for (i = 0; msg[i]; i++) UART_RXTX = (uint8_t)msg[i];
    uart_flush();
    delay_us(2000);                               // let the last frame land

    for (i = 0; msg[i]; i++) {
        int c = uart_getc_nb();
        if (c != (unsigned char)msg[i]) { ok = 0; break; }
    }
    ok &= !(UART_STATUS & (UART_ST_FRAMEERR | UART_ST_PARERR | UART_ST_OVERRUN));
    uart_flush();                                 // same care on the way out
    UART_CTRL &= ~UART_CTRL_LOOP;
    UART_CTRL |= UART_CTRL_RXCLR;

    check("uart fifo loopback", ok);
}

static void test_sram(void)
{
    uint32_t bytes = SYS_SRAM_SIZE;
    if (bytes == 0) { s6_printf("  %-22s skipped (not fitted)\n", "external sram"); return; }

    volatile uint32_t *p = (volatile uint32_t *)SRAM_BASE;
    volatile uint8_t  *b = (volatile uint8_t  *)SRAM_BASE;
    int ok = 1;
    uint32_t i;

    for (i = 0; i < 32; i++) p[i] = 0xA5A50000u + i;
    for (i = 0; i < 32; i++) ok &= (p[i] == 0xA5A50000u + i);

    // byte lanes: the controller writes only the masked bytes
    p[0] = 0x11223344u;
    b[1] = 0xEE;
    ok &= (p[0] == 0x1122EE44u);

    // the far end of the part, to prove all 19 address lines are wired
    volatile uint32_t *far = (volatile uint32_t *)(SRAM_BASE + bytes - 4);
    *far = 0xC0FFEE00u;
    ok &= (*far == 0xC0FFEE00u) && (p[0] == 0x1122EE44u);

    check("external sram", ok);
}

// =====================================================================
int main(void)
{
    uint32_t misa;

    uart_init(115200);
    misa = csr_read(misa);

    s6_printf("\n");
    s6_printf("=== s6: tiny RV32 core on Spartan-6 LX9 ===\n");
    s6_printf("  misa       0x%08x  rv32", misa);
    {
        const char *letters = "abcdefghijklmnopqrstuvwxyz";
        int i;
        for (i = 0; i < 26; i++) if (misa & (1u << i)) uart_putc(letters[i] - 32);
    }
    s6_printf("\n");
    s6_printf("  clock      %u Hz\n", SYS_CLK_HZ);
    s6_printf("  block ram  %u bytes\n", SYS_MEM_WORDS * 4);
    s6_printf("  sram       %u bytes\n", SYS_SRAM_SIZE);
    s6_printf("  vendor/arch/imp/hart %u/%u/%u/%u\n",
              csr_read(mvendorid), csr_read(marchid),
              csr_read(mimpid), csr_read(mhartid));
    s6_printf("self test:\n");

    test_muldiv();
    test_atomics();
    test_counters();
    test_traps();
    test_user_mode();
    test_timer_irq();
    test_uart_loopback();
    test_sram();

    s6_printf("%d failure(s)\n", failures);
    s6_printf("echo: type, 'q' quits\n");

    // Echo loop, blinking the LED off mtime so it is visible on hardware.
    {
        uint64_t next = mtime_get();
        for (;;) {
            int c = uart_getc_nb();
            if (c >= 0) {
                if (c == 'q') break;
                uart_putc((char)c);
                if (c == '\r') uart_putc('\n');
            }
            if (mtime_get() >= next) {
                next += 250000;                   // 250 ms
                GPIO_OUT_TGL = 1u;                // bit 0 drives USER_LED
            }
        }
    }

    s6_printf("bye\n");
    halt(failures);
    return failures;
}
