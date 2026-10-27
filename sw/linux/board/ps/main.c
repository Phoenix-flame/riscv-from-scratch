/* =====================================================================
 * main.c  -  the Cortex-A9's whole job for riscv_linux (Step 54)
 * ---------------------------------------------------------------------
 * The RISC-V's RAM is the PS's DDR, and only the PS can bring that up.
 * `make run PROJECT=riscv_linux` (OpenZynq) programs the PL and starts
 * this on CPU0, from OCM, so it never touches DDR it is training:
 *
 *   1. ps7_init() + ps7_post_config(): clocks, DDR training, the PL's
 *      level shifters and fabric resets (the board's Vivado-exported
 *      ps7_init, `make vivado-init` -- the one known to work on a Mitra);
 *   2. read 0x4000_0000 over M_AXI_GP0: "RVFS" means this bitstream;
 *   3. a short DDR check inside the RISC-V's window (0x1000_0000, 64 MiB),
 *      with the CPU's MMU and caches off, as startup.S leaves them;
 *   4. write run = 1 to 0x4000_0000: the RISC-V leaves reset, and its boot
 *      ROM prints "boot> " on JM1;
 *   5. wait, and report on UART0 (the on-board CH340) when it powers off.
 *
 * After this the PS has nothing to do: the RISC-V owns its DDR window,
 * and nothing on the PS side caches or touches it.
 * ===================================================================== */
#include <stddef.h>
#include <stdint.h>

#define MMIO(a)        (*(volatile uint32_t *)(uintptr_t)(a))
#define UART_BASE      UINT32_C(0xe0000000)    /* UART0 -> CH340, 115200 */
#define RV_CTRL        UINT32_C(0x40000000)    /* read "RVFS"; write bit 0 = run */
#define RV_STATUS      UINT32_C(0x40000004)    /* bit 0 run, bit 1 powered off */
#define RV_ID          UINT32_C(0x52564653)
#define RV_DDR         UINT32_C(0x10000000)    /* = RISC-V 0x8000_0000 */
#define RV_DDR_BYTES   UINT32_C(0x04000000)

extern int ps7_init(void);
extern int ps7_post_config(void);

static void uart_init(void)
{
    MMIO(UART_BASE + 0x00) = 3;                /* reset RX/TX */
    MMIO(UART_BASE + 0x04) = 0x20;             /* 8N1 */
    MMIO(UART_BASE + 0x18) = 124;              /* baud generator, as ddr_test */
    MMIO(UART_BASE + 0x34) = 6;
    MMIO(UART_BASE + 0x00) = 0x14;             /* enable RX/TX */
}

static void putc_(char c)
{
    while (MMIO(UART_BASE + 0x2c) & 16u) {}
    MMIO(UART_BASE + 0x30) = (uint8_t)c;
}

static void puts_(const char *s) { while (*s) { if (*s == '\n') putc_('\r'); putc_(*s++); } }

static void hex(uint32_t v)
{
    static const char d[] = "0123456789abcdef";
    for (int s = 28; s >= 0; s -= 4) putc_(d[(v >> s) & 15u]);
}

/* walking ones on one word, then an address-in-data pattern over 64 KiB at
 * each end of the window: enough to see that DDR answers, not a stress test
 * (OpenZynq's ddr_test is that) */
static int ddr_check(void)
{
    volatile uint32_t *w = (volatile uint32_t *)(uintptr_t)RV_DDR;
    for (uint32_t p = 1; p; p <<= 1) {
        *w = p;
        __asm__ volatile("dmb sy" ::: "memory");
        if (*w != p) { puts_("  data bit fails at 0x"); hex((uint32_t)(uintptr_t)w); puts_("\n"); return -1; }
    }
    const uint32_t ends[2] = { RV_DDR, RV_DDR + RV_DDR_BYTES - 0x10000 };
    for (int e = 0; e < 2; e++) {
        volatile uint32_t *b = (volatile uint32_t *)(uintptr_t)ends[e];
        for (uint32_t i = 0; i < 0x10000 / 4; i++) b[i] = ends[e] + 4 * i;
        __asm__ volatile("dmb sy" ::: "memory");
        for (uint32_t i = 0; i < 0x10000 / 4; i++)
            if (b[i] != ends[e] + 4 * i) {
                puts_("  pattern fails at 0x"); hex(ends[e] + 4 * i);
                puts_(": read 0x"); hex(b[i]); puts_("\n");
                return -1;
            }
        b[0] = 0;
    }
    return 0;
}

int main(void)
{
    int init = ps7_init();
    if (!init) init = ps7_post_config();
    uart_init();
    puts_("\nriscv_linux: the PS side\n");
    if (init) { puts_("  ps7_init failed: 0x"); hex((uint32_t)init); puts_("\n"); for (;;) {} }
    puts_("  ps7_init + ps7_post_config: ok (clocks, DDR trained, PL level shifters on)\n");

    uint32_t id = MMIO(RV_CTRL);
    if (id != RV_ID) {
        puts_("  0x40000000 reads 0x"); hex(id);
        puts_(", not RVFS: the PL is not riscv_linux -- make prog/run it first\n");
        for (;;) {}
    }
    puts_("  bitstream: RVFS\n");

    if (ddr_check()) { puts_("  DDR check FAILED: not releasing the RISC-V\n"); for (;;) {} }
    puts_("  DDR at 0x10000000..0x13ffffff: ok\n");

    MMIO(RV_CTRL) = 1;
    puts_("  RISC-V released: its console is JM1 pin 21 (TX) / 22 (RX), 115200 8N1\n");
    puts_("  send it an image: tools/rvboot send /dev/ttyUSB0 build/linux/linux-board.rvbi\n");

    while (!(MMIO(RV_STATUS) & 2u)) {
        for (volatile int i = 0; i < 1000000; i++) {}
    }
    puts_("riscv_linux: the RISC-V has powered off\n");
    for (;;) __asm__ volatile("wfe");
}
