/* =====================================================================
 * rom_main.c  -  the boot ROM: size RAM, receive an image, fix up the
 *                device tree, and enter the payload
 * ---------------------------------------------------------------------
 * Reset lands here (via rom_start.S) on every power-on and every reset
 * through the test device. The ROM knows the machine from platform.h;
 * what it hands on is the device tree, so the payload does not have to.
 *
 *   1. probe the RAM size (the first offset whose load faults)
 *   2. wait on the UART for a boot image (bootimg.h): hunt for the magic,
 *      check the header CRC, check every segment lands inside the payload
 *      area BEFORE writing a byte, stream the data into place, check the
 *      data CRC -- and on any error say why, discard the rest of that
 *      image, and wait for the next one
 *   3. copy the DTB to the top of RAM; set /memory's size and
 *      /chosen/bootargs
 *   4. delegate the S-level traps and interrupts and mret into the payload
 *      (a0 = hart ID, a1 = DTB), leaving the SBI behind in M-mode
 * ===================================================================== */
#include "rom.h"
#include "lib.h"
#include "fdt.h"
#include "bootimg.h"
#include <stddef.h>

const struct ns16550 rom_uart = { UART_BASE, 2, 4 };
uint32_t ram_size;

extern const uint8_t _dtb_start[], _dtb_end[];
void enter_payload(uint32_t entry, uint32_t hartid, uint32_t dtb, int mmode)
    __attribute__((noreturn));

static void rom_putc(int c) { ns16550_putc(&rom_uart, c); }

uint64_t rdtime(void)
{
    uint32_t hi, lo;
    do { hi = csr_read(0xc81); lo = csr_read(0xc01); } while (hi != csr_read(0xc81));
    return ((uint64_t)hi << 32) | lo;
}

void fw_poweroff(int code)
{
    ns16550_flush(&rom_uart);
    *(volatile uint32_t *)TEST_BASE = code ? (TEST_FAIL | ((uint32_t)code << 16)) : TEST_PASS;
    for (;;) { }
}

void fw_reset(void)
{
    ns16550_flush(&rom_uart);
    *(volatile uint32_t *)TEST_BASE = TEST_RESET;
    for (;;) { }
}

void rom_panic(uint32_t cause, uint32_t epc, uint32_t tval)
{
    printf("\nrvboot: unexpected trap in the ROM: mcause 0x%x mepc 0x%08x mtval 0x%08x\n",
           cause, epc, tval);
    ns16550_flush(&rom_uart);
}

uint32_t probe_ram(void);                 /* rom_start.S: loads until one faults */

/* ---- receiving ------------------------------------------------------- */
static unsigned line_err;

static int rx(void)
{
    for (;;) {
        int lsr = ns16550_lsr(&rom_uart);
        line_err |= lsr & (UART_LSR_OE | UART_LSR_PE | UART_LSR_FE);
        if (lsr & UART_LSR_DR) return ns16550_rbr(&rom_uart);
    }
}

/* receive n bytes, folding each into a running CRC as it arrives: there
 * is no flow control, so the ROM may never fall behind the line for
 * longer than the 16-byte FIFO can cover (see report()) */
static uint32_t rx_bytes(void *dst, uint32_t n, uint32_t crc)
{
    uint8_t *p = dst;
    while (n--) { *p = (uint8_t)rx(); crc = crc32_byte(crc, *p++); }
    return crc;
}

/* after an error: throw away the rest of the image until the line has
 * been quiet for 32 character times */
static uint32_t drain(void)
{
    const uint64_t quiet = 32ull * 10 * 16 * UART_DIVISOR;
    uint32_t n = 0;
    uint64_t last = rdtime();
    while (rdtime() - last < quiet)
        if (ns16550_getc(&rom_uart) >= 0) { n++; last = rdtime(); }
    line_err = 0;
    return n;
}

static struct rvbi_header hdr;
static struct rvbi_seg    seg[RVBI_MAX_SEGS];
static char               cmdline[RVBI_MAX_CMD + 1];

/* What went wrong, if anything. Nothing is printed while an image is
 * arriving: there is no flow control, and a line of text takes as long
 * to send as a line of image takes to receive -- the 16-byte RX FIFO
 * would overflow. The report comes after the data, or after the rest
 * of a bad image has been drained. */
enum { IMG_OK, IMG_BAD_HDR, IMG_HDR_CRC, IMG_RANGE, IMG_SIZES, IMG_ENTRY, IMG_LINE, IMG_DATA_CRC };
static int      bad_seg;
static uint32_t crc_got, rx_err, rx_cycles, rx_total;

static int load_image(void)
{
    uint32_t w = 0;
    line_err = 0;
    while (w != RVBI_MAGIC) w = (w >> 8) | ((uint32_t)rx() << 24);   /* skip line noise */
    hdr.magic = w;
    /* the header CRC covers the header with hdr_crc itself as zero */
    const unsigned pre = offsetof(struct rvbi_header, hdr_crc);
    uint32_t crc = crc32(0, &hdr, 4) ^ 0xFFFFFFFFu;
    crc = rx_bytes((uint8_t *)&hdr + 4, pre - 4, crc);
    rx_bytes(&hdr.hdr_crc, 4, 0);
    for (int i = 0; i < 4; i++) crc = crc32_byte(crc, 0);
    if (hdr.version != RVBI_VERSION || hdr.nseg == 0 || hdr.nseg > RVBI_MAX_SEGS ||
        hdr.cmdline_len > RVBI_MAX_CMD)
        return IMG_BAD_HDR;
    crc = rx_bytes(seg, hdr.nseg * sizeof seg[0], crc);
    crc = rx_bytes(cmdline, hdr.cmdline_len, crc);
    cmdline[hdr.cmdline_len] = '\0';
    crc_got = ~crc;
    if (crc_got != hdr.hdr_crc) return IMG_HDR_CRC;

    /* every check happens before the first byte is written */
    uint32_t total = 0;
    int entry_ok = 0;
    for (int i = 0; i < hdr.nseg; i++) {
        uint32_t a = seg[i].addr, end = a + seg[i].memsz;
        if (seg[i].filesz > seg[i].memsz || end < a || a < PAYLOAD_BASE || end > DTB_ADDR) {
            bad_seg = i;
            return IMG_RANGE;
        }
        if (hdr.entry >= a && hdr.entry < a + seg[i].filesz) entry_ok = 1;
        total += seg[i].filesz;
    }
    if (total != hdr.data_size) return IMG_SIZES;
    if (!entry_ok)              return IMG_ENTRY;

    uint64_t t0 = rdtime();
    crc = 0xFFFFFFFFu;
    for (int i = 0; i < hdr.nseg; i++) {
        uint8_t *p = (uint8_t *)seg[i].addr;
        crc = rx_bytes(p, seg[i].filesz, crc);
        memset(p + seg[i].filesz, 0, seg[i].memsz - seg[i].filesz);       /* .bss */
    }
    crc_got   = ~crc;
    rx_cycles = (uint32_t)(rdtime() - t0);
    rx_total  = total;
    rx_err    = line_err;
    if (rx_err)                    return IMG_LINE;
    if (crc_got != hdr.data_crc)   return IMG_DATA_CRC;
    return IMG_OK;
}

static void report(int err)
{
    if (err == IMG_BAD_HDR) {
        printf("RVBI header: version %u, %u segments, %u-byte command line\n"
               "  error: not an image this ROM can load\n", hdr.version, hdr.nseg, hdr.cmdline_len);
        return;
    }
    if (err == IMG_HDR_CRC) {
        printf("RVBI header\n  error: header CRC32 0x%08x, image says 0x%08x\n", crc_got, hdr.hdr_crc);
        return;
    }
    printf("RVBI v%u: %u segment%s, entry 0x%08x, %c-mode\n", hdr.version, hdr.nseg,
           hdr.nseg == 1 ? "" : "s", hdr.entry, (hdr.flags & RVBI_F_MMODE) ? 'M' : 'S');
    if (hdr.cmdline_len) printf("  bootargs \"%s\"\n", cmdline);
    for (int i = 0; i < hdr.nseg; i++)
        printf("  segment %u: 0x%08x  file %5u  mem %5u\n", i, seg[i].addr, seg[i].filesz, seg[i].memsz);
    switch (err) {
    case IMG_RANGE:
        printf("  error: segment %u [0x%08x, 0x%08x) is outside the payload area [0x%08x, 0x%08x)\n",
               bad_seg, seg[bad_seg].addr, seg[bad_seg].addr + seg[bad_seg].memsz, PAYLOAD_BASE, DTB_ADDR);
        break;
    case IMG_SIZES: printf("  error: segment sizes do not add up to the data size\n"); break;
    case IMG_ENTRY: printf("  error: the entry point is not in a loaded segment\n"); break;
    case IMG_LINE:
        printf("  error: receive error, LSR 0x%02x (overrun 2, parity 4, framing 8)\n", rx_err);
        break;
    case IMG_DATA_CRC:
        printf("  error: data CRC32 0x%08x, image says 0x%08x\n", crc_got, hdr.data_crc);
        break;
    default:
        printf("  data: %u bytes, CRC32 0x%08x ok (%u cycles, %u per byte)\n",
               rx_total, crc_got, rx_cycles, rx_total ? rx_cycles / rx_total : 0);
    }
}

/* ---- the device tree handed on --------------------------------------- */
static int fixup_dtb(void *dtb)
{
    memcpy(dtb, _dtb_start, (size_t)(_dtb_end - _dtb_start));
    int err = fdt_check(dtb);
    if (err) return err;
    int mem = fdt_path_offset(dtb, "/memory");
    int chosen = fdt_path_offset(dtb, "/chosen");
    if (mem < 0 || chosen < 0) return FDT_ERR_NOTFOUND;
    uint32_t reg[2] = { cpu_to_fdt32(RAM_BASE), cpu_to_fdt32(ram_size) };
    if ((err = fdt_setprop(dtb, DTB_AREA, mem, "reg", reg, sizeof reg))) return err;
    return fdt_setprop_string(dtb, DTB_AREA, chosen, "bootargs", cmdline);
}

void rom_main(void)
{
    lib_putc = rom_putc;
    ram_size = probe_ram();
    ns16550_init(&rom_uart, UART_DIVISOR);

    printf("\nrvfs boot ROM (Step 49), hart %u\n", csr_read(mhartid));
    printf("  RAM      0x%08x, %u KiB (probed)\n", RAM_BASE, ram_size >> 10);
    printf("  payloads [0x%08x, 0x%08x), DTB at 0x%08x\n", PAYLOAD_BASE, DTB_ADDR, DTB_ADDR);
    printf("  SBI v2.0 resident: BASE TIME DBCN SRST + legacy 0.1\n");
    for (;;) {
        puts_raw("boot> ");
        int err = load_image();
        if (err == IMG_OK) { report(err); break; }
        uint32_t rest = drain();
        report(err);
        printf("  (discarded %u more bytes)\n", rest);
    }

    void *dtb = (void *)DTB_ADDR;
    int err = fixup_dtb(dtb);
    if (err) {
        printf("  error: device tree fixup failed (%d)\n", err);
        fw_poweroff(0x12);
    }
    printf("  dtb: %u bytes, memory = <0x%08x 0x%x>, bootargs set\n",
           fdt_totalsize(dtb), RAM_BASE, ram_size);

    int mmode = (hdr.flags & RVBI_F_MMODE) != 0;
    if (!mmode) {
        /* the S-level traps go straight to the payload's stvec ... */
        csr_write(medeleg, (1u << 0) | (1u << 2) | (1u << 3) | (1u << 8) |   /* misaligned fetch,
                                                         illegal, breakpoint, ecall from U */
                           (1u << 1) | (1u << 5) | (1u << 7) |              /* access faults */
                           (1u << 12) | (1u << 13) | (1u << 15));           /* page faults */
        csr_write(mideleg, (1u << 1) | (1u << 5) | (1u << 9));              /* SSI, STI, SEI */
    }
    /* ... ecall from S (cause 9) and the machine timer stay here: the SBI */
    printf("  -> %c-mode at 0x%08x, a0 = hart %u, a1 = dtb 0x%08x\n\n",
           mmode ? 'M' : 'S', hdr.entry, csr_read(mhartid), (uint32_t)dtb);
    ns16550_flush(&rom_uart);
    enter_payload(hdr.entry, csr_read(mhartid), (uint32_t)dtb, mmode);
}
