/* =====================================================================
 * host_test.c  -  bootbin.c and qspi.c on a PC (make test, Step 56)
 * ---------------------------------------------------------------------
 * hw_rd()/hw_wr() land in a model of the Zynq QSPI controller (as UG585
 * describes it: TXD0/TXD1, RXD, manual chip select and start, linear mode)
 * with a 16 MiB SPI NOR flash behind it that is strict about what a real
 * one cares about: write enable before every program or erase, nothing
 * while busy, programming only clears bits, a page program wraps inside its
 * 256-byte page. What it cannot show is that the silicon agrees with this
 * reading of the manual; the board does that.
 * ===================================================================== */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "zynq.h"
#include "bootbin.h"
#include "qspi.h"

#define FLASH  QSPI_FLASH_BYTES
static uint8_t flash[FLASH];
static int fails;

#define CHECK(c, ...) do { if (!(c)) { printf("FAIL: " __VA_ARGS__); printf("\n"); fails++; } } while (0)
static void model_error(const char *m) { printf("MODEL: %s\n", m); fails++; }

/* ---- the flash ---------------------------------------------------- */
static struct {
    int wel, busy, protect, selected;
    uint32_t n, cmd, addr, pp_count;
    uint8_t page[256];
    uint32_t erases, programs;
} f;

static void flash_select(void) { f.selected = 1; f.n = 0; f.pp_count = 0; }

static uint8_t flash_byte(uint8_t in)
{
    uint32_t i = f.n++;
    if (i == 0) {
        f.cmd = in;
        if (f.busy && in != 0x05) model_error("a command while the flash is busy");
        if (in != 0x05 && in != 0x06 && in != 0x9f && in != 0x02 && in != 0xd8) model_error("an unknown command");
        if (in == 0x05 && f.busy) f.busy--;
        return 0xff;
    }
    switch (f.cmd) {
    case 0x05: return (uint8_t)((f.busy ? 1 : 0) | (f.wel ? 2 : 0));
    case 0x9f: { static const uint8_t id[3] = { 0xef, 0x40, 0x18 }; return i <= 3 ? id[i - 1] : 0xff; }
    case 0x02: case 0xd8:
        if (i <= 3) { f.addr = (f.addr << 8 | in) & 0xffffff; if (i == 1) f.addr = in; return 0xff; }
        if (f.cmd == 0x02) { f.page[(f.addr + f.pp_count) & 0xff] = in; f.pp_count++; }
        else model_error("data after a block erase address");
        return 0xff;
    }
    return 0xff;
}

static void flash_deselect(void)
{
    f.selected = 0;
    if (f.n == 0) return;
    if (f.cmd == 0x06) { if (!f.protect) f.wel = 1; return; }
    if (f.cmd == 0x02 || f.cmd == 0xd8) {
        if (f.n < 4) { model_error("a short address"); return; }
        if (!f.wel) { model_error("program or erase without write enable"); return; }
        f.wel = 0;
        if (f.cmd == 0xd8) {
            if (f.addr & 0xffff) model_error("an erase address inside a block");
            memset(flash + (f.addr & ~0xffffu), 0xff, 0x10000);
            f.busy = 7; f.erases++;
        } else {
            if (f.pp_count > 256) model_error("more than a page in one program");
            uint32_t base = f.addr & ~0xffu;
            for (uint32_t k = 0; k < f.pp_count && k < 256; k++) {
                uint32_t a = base + ((f.addr + k) & 0xff);
                flash[a] &= f.page[(f.addr + k) & 0xff];
            }
            f.busy = 2; f.programs++;
        }
    }
}

/* ---- the controller ---------------------------------------------- */
#define Q 0xe000d000u
static uint32_t cr = 0x00020000, er, lq = 0x03a00000, isr_dis;
static uint32_t txq[128][2], ntx, rxq[128], nrx, rxhead;

static void shift_out(void)
{
    if (!er) model_error("a transfer with the controller disabled");
    if (lq >> 31) model_error("an I/O transfer in linear mode");
    if (!(cr & (1u << 14)) || (cr & (1u << 10))) model_error("a transfer without chip select held");
    for (uint32_t k = 0; k < ntx; k++) {
        uint32_t w = txq[k][0], nb = txq[k][1], r = 0;
        for (uint32_t b = 0; b < nb; b++) r |= (uint32_t)flash_byte((uint8_t)(w >> (8 * b))) << (8 * b);
        if (nb < 4) r <<= 8 * (4 - nb);        /* short transfers land high, as on the chip */
        if (nrx == 63) model_error("RX FIFO overflow");
        rxq[(rxhead + nrx++) % 128] = r;
    }
    ntx = 0;
}

uint32_t hw_rd(uint32_t a)
{
    switch (a) {
    case Q + 0x00: return cr;
    case Q + 0x04: return nrx ? 1u << 4 : 0;
    case Q + 0x14: return er;
    case Q + 0x20: {
        if (!nrx) { model_error("RXD read with the FIFO empty"); return 0; }
        uint32_t v = rxq[rxhead]; rxhead = (rxhead + 1) % 128; nrx--; return v;
    }
    case Q + 0xa0: return lq;
    }
    printf("MODEL: read of 0x%08x\n", a); fails++;
    return 0;
}

void hw_wr(uint32_t a, uint32_t v)
{
    switch (a) {
    case Q + 0x00: {
        int was = f.selected, now = (v & (1u << 14)) && !(v & (1u << 10));
        if (!(v & (1u << 31)) || ((v >> 6) & 3) != 3) model_error("CR without flash mode or 32-bit FIFO");
        if (er && ((v ^ cr) & ~((1u << 10) | (1u << 16)))) model_error("CR reconfigured while enabled");
        cr = v & ~(1u << 16);
        if (now && !was) flash_select();
        if (v & (1u << 16)) shift_out();
        if (!now && was) flash_deselect();
        return;
    }
    case Q + 0x0c: isr_dis = v; return;
    case Q + 0x14: er = v & 1; return;
    case Q + 0x1c: case Q + 0x80:
        if (ntx == 63) { model_error("TX FIFO overflow"); return; }
        txq[ntx][0] = v; txq[ntx][1] = a == Q + 0x1c ? 4 : 1; ntx++;
        return;
    case Q + 0xa0:
        if (er) model_error("LQSPI_CFG written while enabled");
        lq = v; return;
    }
    printf("MODEL: write of 0x%08x to 0x%08x\n", v, a); fails++;
}

const uint8_t *host_flash_map(void)
{
    if (!er || !(lq >> 31) || (cr & (1u << 14)) || (lq & 0xff) != 0x0b)
        model_error("a linear read without linear mode set up");
    return flash;
}

/* ---- the tests ----------------------------------------------------- */
static uint8_t *slurp(const char *path, uint32_t *n)
{
    FILE *fp = fopen(path, "rb");
    if (!fp) { perror(path); exit(2); }
    fseek(fp, 0, SEEK_END);
    long sz = ftell(fp);
    rewind(fp);
    uint8_t *b = malloc((size_t)sz + 4);
    if (fread(b, 1, (size_t)sz, fp) != (size_t)sz) exit(2);
    fclose(fp);
    *n = (uint32_t)sz;
    return b;
}

static uint32_t le32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

/* is it all there: the RVBI's own data CRC over what bootbin found */
static int image_whole(const struct bootbin *b)
{
    uint32_t meta = b->img_bytes - le32(b->img + 20);
    return crc32_update(0, b->img + meta, le32(b->img + 20)) == le32(b->img + 24);
}

static void expect_refused(const uint8_t *img, uint32_t n, const char *what, const char *want)
{
    struct bootbin b;
    const char *why = "";
    int r = bootbin_parse(img, n, &b, &why);
    CHECK(r != 0 && strstr(why, want), "%s: want \"%s\", got %d \"%s\"", what, want, r, why);
    if (r != 0 && strstr(why, want)) printf("ok   %s: refused (%s)\n", what, why);
}

static void progress(uint32_t done, uint32_t n) { (void)done; (void)n; }

int main(int argc, char **argv)
{
    if (argc != 2) { fprintf(stderr, "usage: host_test BOOT.BIN\n"); return 2; }
    uint32_t n;
    uint8_t *boot = slurp(argv[1], &n);
    struct bootbin b;
    const char *why = "";

    /* 1. the parser, on the buffer as received */
    int r = bootbin_parse(boot, n, &b, &why);
    CHECK(r == 0, "parse: %s", why);
    if (!r) {
        CHECK(b.bit[12] == 0xaa995566u, "the bitstream's sync word is not where PCAP wants it");
        CHECK(image_whole(&b), "the RVBI image's data CRC does not match");
        printf("ok   parse: %u partitions, bitstream %u bytes, RVBI %u bytes, data CRC good\n",
               b.nparts, 4 * b.bit_words, b.img_bytes);
    }

    /* 2. what it must refuse */
    uint8_t *m = malloc(n);
    memcpy(m, boot, n); m[0x20] ^= 1;
    expect_refused(m, n, "no width word", "no boot header");
    memcpy(m, boot, n); m[0xc80 + 64 + 24] ^= 0x10;
    expect_refused(m, n, "a partition header changed", "checksum");
    memcpy(m, boot, n);
    if (!r) m[(uint32_t)(b.img - boot) + 40] ^= 1;      /* inside the RVBI segment table */
    expect_refused(m, n, "an RVBI header bit flipped", "no RISC-V image");
    expect_refused(boot, n - 4096, "cut short", "past the end");
    expect_refused(boot, 100, "a few bytes", "too short");
    memset(m, 0xff, n);
    expect_refused(m, n, "erased flash", "no boot header");

    /* 3. writing it: over random contents, so the erase matters */
    srand(56);
    for (uint32_t i = 0; i < FLASH; i++) flash[i] = (uint8_t)rand();
    r = qspi_write(boot, n, progress, &why);
    CHECK(r == 0, "qspi_write: %s", why);
    CHECK(memcmp(flash, boot, n) == 0, "the flash does not hold the image");
    uint32_t end = (n + 0xffff) & ~0xffffu;
    int erased = 1;
    for (uint32_t i = n; i < end; i++) erased &= flash[i] == 0xff;
    CHECK(erased, "the rest of the last block is not erased");
    CHECK(f.erases == end / 0x10000, "%u erases for %u blocks", f.erases, end / 0x10000);
    if (!r) printf("ok   write: %u bytes, %u block erases, %u page programs, read back\n",
                   n, f.erases, f.programs);

    /* 4. then the FSBL's view: the flash through linear mode */
    r = bootbin_parse(qspi_map(), FLASH, &b, &why);
    CHECK(r == 0 && image_whole(&b), "parse from flash: %s", why);
    if (!r) printf("ok   boot from flash: found both payloads through the linear map\n");
    uint32_t id = qspi_jedec_id();
    CHECK(id == 0xef4018, "JEDEC ID 0x%06x", id);
    if (id == 0xef4018) printf("ok   JEDEC ID 0x%06x (16 MiB)\n", id);

    /* 5. an odd length, and a flash that will not write */
    r = qspi_write(boot, n - 3, progress, &why);
    CHECK(r == 0 && memcmp(flash, boot, n - 3) == 0, "odd length: %s", why);
    if (!r) printf("ok   write of %u bytes (not a multiple of 4)\n", n - 3);
    f.protect = 1;
    r = qspi_write(boot, n, progress, &why);
    CHECK(r != 0 && strstr(why, "write enable"), "a protected flash: %d %s", r, why);
    if (r) printf("ok   a flash that ignores write enable: refused (%s)\n", why);
    CHECK((lq >> 31) && er, "left out of linear mode after a failure");

    printf(fails ? "PS-HOST: %d FAILED\n" : "PS-HOST: ALL PASS\n", fails);
    return fails != 0;
}
