/* =====================================================================
 * main.c  -  the Cortex-A9's whole job for riscv_linux (Steps 54, 56)
 * ---------------------------------------------------------------------
 * The RISC-V's RAM is the PS's DDR, and only the PS can bring that up.
 * This runs on CPU0 from OCM, so it never touches DDR it is training,
 * started one of two ways:
 *
 *   JTAG boot mode: `make run PROJECT=riscv_linux` (OpenZynq) programs the
 *     PL over JTAG, then loads and starts this;
 *   QSPI boot mode (Step 56): the BootROM loads this from BOOT.BIN in flash,
 *     as the FSBL, and this does the rest.
 *
 *   1. ps7_init(): clocks, MIO, DDR training (the board's Vivado-exported
 *      ps7_init, `make vivado-init` -- the one known to work on a Mitra);
 *      then FCLK1, the RISC-V's clock, to IO PLL / 30 = 33.33 MHz (Step 58);
 *   2. QSPI boot only: find BOOT.BIN's bitstream and program the PL with it
 *      through PCAP (pcap.c);
 *   3. ps7_post_config(): the PL's level shifters and fabric resets;
 *   4. read 0x4000_0000 over M_AXI_GP0: "RVFS" means this bitstream;
 *   5. a short DDR check inside the RISC-V's window (0x1000_0000, 64 MiB);
 *   6. QSPI boot only: copy BOOT.BIN's RISC-V image to 0x1300_0000, where
 *      the RISC-V's ROM looks for one (BOOTMEM_ADDR, sw/boot/platform.h);
 *   7. write run = 1 to 0x4000_0000: the RISC-V leaves reset;
 *   8. then serve UART0 (the on-board CH340): `tools/rvboot flash` sends a
 *      BOOT.BIN to write to the QSPI flash; and report when the RISC-V
 *      powers off.
 *
 * The RISC-V owns its DDR window; nothing on the PS side caches it.
 * ===================================================================== */
#include <stddef.h>
#include <stdint.h>
#include "zynq.h"
#include "bootbin.h"
#include "qspi.h"
#include "pcap.h"

#define RV_CTRL        UINT32_C(0x40000000)    /* read "RVFS"; write bit 0 = run */
#define RV_STATUS      UINT32_C(0x40000004)    /* bit 0 run, bit 1 powered off */
#define RV_ID          UINT32_C(0x52564653)
#define RV_DDR         UINT32_C(0x10000000)    /* = RISC-V 0x8000_0000 */
#define RV_DDR_BYTES   UINT32_C(0x04000000)
#define RV_IMG         UINT32_C(0x13000000)    /* = RISC-V BOOTMEM_ADDR 0x8300_0000 */
#define RV_IMG_ROOM    (RV_DDR + RV_DDR_BYTES - 0x2000 - RV_IMG)   /* below the DT */
/* PS-only DDR, below the RISC-V's window: the bitstream on its way to the
 * PCAP, and a BOOT.BIN on its way to the flash */
#define BIT_BUF        UINT32_C(0x01000000)
#define RX_BUF         UINT32_C(0x02000000)

extern int ps7_init(void);
extern int ps7_post_config(void);

/* FCLK1 = IO PLL / (DIVISOR0 * DIVISOR1) = 1000 MHz / (6 * 5) = 33.33 MHz:
 * the RISC-V's clock and HP0's, which its ROM, device tree, U-Boot and Linux
 * all assume (PLAT_CLOCK_HZ = 33333333; UART divisor 18 is 115,741 baud).
 * Step 57 ran it at IO PLL / 90 = 11.11 MHz; Step 58's core routes at
 * about 41 MHz, so 33.33 MHz is the fastest baud-exact step with margin.
 * ps7_init leaves it at 125 MHz. The RISC-V is in reset until "run", so the
 * change cannot catch it mid-cycle. */
static void fclk1_init(void)
{
    hw_wr(SLCR_UNLOCK, 0xdf0d);
    hw_wr(SLCR_FPGA1_CLK, (UINT32_C(5) << 20) | (UINT32_C(6) << 8));
    hw_wr(SLCR_LOCK, 0x767b);
}

static void uart_init(void)
{
    hw_wr(UART0 + 0x00, 3);                    /* reset RX/TX */
    hw_wr(UART0 + 0x04, 0x20);                 /* 8N1 */
    hw_wr(UART0 + 0x18, 124);                  /* baud generator, as ddr_test */
    hw_wr(UART0 + 0x34, 6);
    hw_wr(UART0 + 0x00, 0x14);                 /* enable RX/TX */
}

static void putc_(char c)
{
    while (hw_rd(UART_SR) & 16u) {}
    hw_wr(UART_FIFO, (uint8_t)c);
}

static void puts_(const char *s) { while (*s) { if (*s == '\n') putc_('\r'); putc_(*s++); } }

static void hex(uint32_t v)
{
    static const char d[] = "0123456789abcdef";
    for (int s = 28; s >= 0; s -= 4) putc_(d[(v >> s) & 15u]);
}

static void dec(uint32_t v)
{
    char b[12];
    int i = 0;
    do { b[i++] = (char)('0' + v % 10); v /= 10; } while (v);
    while (i) putc_(b[--i]);
}

static int rx_ready(void) { return !(hw_rd(UART_SR) & 2u); }
static uint8_t getc_(void) { while (!rx_ready()) {} return (uint8_t)hw_rd(UART_FIFO); }

static void halt(const char *msg) { puts_(msg); for (;;) __asm__ volatile("wfe"); }

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

static void copy_words(uint32_t dst, const void *src, uint32_t bytes, int swap)
{
    volatile uint32_t *d = (volatile uint32_t *)(uintptr_t)dst;
    const uint32_t *s = (const uint32_t *)src;
    for (uint32_t i = 0; i < (bytes + 3) / 4; i++) {
        uint32_t v = s[i];
        d[i] = swap ? __builtin_bswap32(v) : v;
    }
    __asm__ volatile("dsb sy" ::: "memory");
}

static void say_flash(const struct bootbin *b)
{
    puts_(" bitstream "); dec(4 * b->bit_words);
    puts_(" bytes, RISC-V image "); dec(b->img_bytes); puts_(" bytes");
}

/* QSPI boot: the PL from BOOT.BIN, through a copy in DDR */
static void program_pl(const struct bootbin *b)
{
    const char *why = "";
    int order = pcap_order(b->bit, b->bit_words);
    if (order < 0) halt("  the bitstream partition has no sync word: not loading it\n");
    copy_words(BIT_BUF, b->bit, 4 * b->bit_words, order);
    if (pcap_load((const uint32_t *)(uintptr_t)BIT_BUF, b->bit_words, &why)) {
        puts_("  PL: "); puts_(why); halt("\n");
    }
    puts_("  PL programmed from flash (PCAP, "); dec(4 * b->bit_words); puts_(" bytes)\n");
}

/* ---- writing BOOT.BIN to the flash: tools/rvboot flash -----------------
 * "RVFLASH1", length and CRC-32 (little-endian words), "flash: receiving"
 * back, then the bytes. Checked whole (CRC, and that it is a BOOT.BIN with
 * both payloads) before anything is erased. */
static const char flash_magic[] = "RVFLASH1";

static void flash_progress(uint32_t done, uint32_t n)
{
    if (done == n || done % 0x100000 == 0) {
        puts_("flash: "); dec(done >> 10); puts_(" of "); dec(n >> 10); puts_(" KiB\n");
    }
}

static uint32_t get32(void)
{
    uint32_t v = 0;
    for (int i = 0; i < 4; i++) v |= (uint32_t)getc_() << (8 * i);
    return v;
}

static void serve_flash(void)
{
    uint32_t n = get32(), crc = get32();
    const char *why = "";
    struct bootbin b;
    if (n < 0xa0 || n > QSPI_FLASH_BYTES) { puts_("flash: refused: length out of range\n"); return; }
    puts_("flash: receiving "); dec(n); puts_(" bytes\n");
    volatile uint8_t *buf = (volatile uint8_t *)(uintptr_t)RX_BUF;
    for (uint32_t i = 0; i < n; i++) buf[i] = getc_();
    const uint8_t *img = (const uint8_t *)(uintptr_t)RX_BUF;
    uint32_t got = crc32_update(0, img, n);
    if (got != crc) {
        puts_("flash: FAILED: CRC-32 0x"); hex(got); puts_(", sent 0x"); hex(crc);
        puts_(": bytes lost on the way, nothing written\n");
        return;
    }
    if (bootbin_parse(img, n, &b, &why)) {
        puts_("flash: FAILED: not riscv_linux's BOOT.BIN: "); puts_(why); puts_(". Nothing written\n");
        return;
    }
    puts_("flash: CRC ok, BOOT.BIN:"); say_flash(&b); puts_("\n");
    puts_("flash: JEDEC ID 0x"); hex(qspi_jedec_id()); puts_("; erasing and writing\n");
    if (qspi_write(img, n, flash_progress, &why)) { puts_("flash: FAILED: "); puts_(why); puts_("\n"); return; }
    puts_("flash: done, "); dec(n);
    puts_(" bytes written and read back. Set the boot mode to QSPI and power-cycle.\n");
}

int main(void)
{
    const int qspi_boot = (hw_rd(SLCR_BOOT_MODE) & 7u) == BOOT_MODE_QSPI;
    const char *why = "";
    struct bootbin b;
    int init = ps7_init();
    if (!init) fclk1_init();
    uart_init();
    puts_("\nriscv_linux: the PS side\n");
    if (init) { puts_("  ps7_init failed: 0x"); hex((uint32_t)init); halt("\n"); }
    puts_(qspi_boot ? "  QSPI boot: this is the FSBL\n" : "  JTAG boot\n");
    puts_("  FCLK1 (the RISC-V's clock): IO PLL / 30 = 33.33 MHz, reads back 0x");
    hex(hw_rd(SLCR_FPGA1_CLK)); puts_("\n");

    int have = bootbin_parse(qspi_map(), QSPI_FLASH_BYTES, &b, &why) == 0;
    if (qspi_boot) {
        if (!have) { puts_("  flash: "); puts_(why); halt("\n"); }
        program_pl(&b);
    }
    init = ps7_post_config();
    if (init) { puts_("  ps7_post_config failed: 0x"); hex((uint32_t)init); halt("\n"); }
    puts_("  ps7_init + ps7_post_config: ok (clocks, DDR trained, PL level shifters on)\n");

    uint32_t id = hw_rd(RV_CTRL);
    if (id != RV_ID) {
        puts_("  0x40000000 reads 0x"); hex(id);
        halt(", not RVFS: the PL is not riscv_linux -- make prog/run it first\n");
    }
    puts_("  bitstream: RVFS\n");

    if (ddr_check()) halt("  DDR check FAILED: not releasing the RISC-V\n");
    puts_("  DDR at 0x10000000..0x13ffffff: ok\n");

    if (qspi_boot) {
        if (b.img_bytes > RV_IMG_ROOM) halt("  the RISC-V image is too big for its place in DDR\n");
        copy_words(RV_IMG, b.img, b.img_bytes, 0);
        puts_("  RISC-V image copied from flash to 0x13000000 ("); dec(b.img_bytes); puts_(" bytes)\n");
    } else {
        /* DDR keeps its contents over `make run` without a power cycle:
         * an image a QSPI boot left must not be booted again from JTAG */
        hw_wr(RV_IMG, 0);
        if (have) {
            puts_("  flash holds a riscv_linux BOOT.BIN:"); say_flash(&b);
            puts_(" (it boots with the boot mode on QSPI)\n");
        } else {
            puts_("  flash: "); puts_(why); puts_("\n");
        }
    }

    hw_wr(RV_CTRL, 1);
    puts_("  RISC-V released: its console is JM1 pin 21 (TX) / 22 (RX), 115200 8N1\n");
    if (qspi_boot)
        puts_("  its ROM boots the image in 1 s; a key on its console first gets \"boot> \"\n");
    else
        puts_("  send it an image: tools/rvboot send /dev/ttyUSB0 build/linux/linux-board.rvbi\n");
    puts_("  write BOOT.BIN to flash from here: tools/rvboot flash <this port> BOOT.BIN\n");

    int matched = 0, off = 0;
    for (;;) {
        if (rx_ready()) {
            char c = (char)getc_();
            matched = c == flash_magic[matched] ? matched + 1 : (c == flash_magic[0]);
            if (!flash_magic[matched]) { matched = 0; serve_flash(); }
        }
        if (!off && (hw_rd(RV_STATUS) & 2u)) { off = 1; puts_("riscv_linux: the RISC-V has powered off\n"); }
    }
}
