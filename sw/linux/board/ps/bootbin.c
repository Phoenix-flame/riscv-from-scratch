/* =====================================================================
 * bootbin.c  -  BOOT.BIN's partition table, and the RVBI header check
 * ---------------------------------------------------------------------
 * The layout, as zynq-mkbootimage writes it (and bootgen before it):
 *
 *   0x020  width detection word 0xaa995566     0x024  "XNLX"
 *   0x098  byte offset of the image header table (its word 1: the count)
 *   0x09c  byte offset of the partition header table, 64 bytes an entry:
 *            word 1  the partition's length in words (unencrypted)
 *            word 5  its offset from the start of BOOT.BIN, in words
 *            word 6  attributes: [6:4] the destination, 2 = the PL
 *            word 15 ~(the sum of words 0..14)
 *
 * Only aligned word loads and byte loads: with the MMU off, as startup.S
 * leaves it, an unaligned load faults.
 * ===================================================================== */
#include "bootbin.h"

#define BH_WIDTH      0x20
#define BH_ID         0x24
#define BH_IMG_TAB    0x98
#define BH_PART_TAB   0x9c
#define WIDTH_DETECT  UINT32_C(0xaa995566)
#define ID_XNLX       UINT32_C(0x584c4e58)
#define PH_BYTES      64
#define ATTR_DEST     (UINT32_C(7) << 4)
#define ATTR_DEST_PL  (UINT32_C(2) << 4)
#define MAX_PARTS     32

/* sw/boot/bootimg.h, which this directory does not carry into OpenZynq */
#define RVBI_MAGIC    UINT32_C(0x49425652)     /* "RVBI" */
#define RVBI_HDR      32
#define RVBI_SEG      12
#define RVBI_MAX_SEGS 8

static uint32_t w32(const uint8_t *p) { return *(const uint32_t *)(const void *)p; }
static uint32_t b16(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8; }
static uint32_t b32(const uint8_t *p) { return b16(p) | b16(p + 2) << 16; }

uint32_t crc32_update(uint32_t crc, const uint8_t *p, uint32_t n)
{
    static uint32_t table[256];
    if (!table[1])
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = (c & 1) ? UINT32_C(0xedb88320) ^ (c >> 1) : c >> 1;
            table[i] = c;
        }
    crc = ~crc;
    while (n--) crc = table[(crc ^ *p++) & 0xff] ^ (crc >> 8);
    return ~crc;
}

/* an RVBI image in the first `room` bytes at p: its header CRC (the header
 * with hdr_crc as 0, the segment table and the command line), as the ROM
 * checks it before it writes anything. Its data CRC is the ROM's to check. */
static int rvbi_ok(const uint8_t *p, uint32_t room, uint32_t *bytes)
{
    static const uint8_t zero[4];
    if (room < RVBI_HDR || b32(p) != RVBI_MAGIC) return 0;
    uint32_t nseg = b16(p + 6), clen = b16(p + 16), dsize = b32(p + 20), hcrc = b32(p + 28);
    if (nseg == 0 || nseg > RVBI_MAX_SEGS) return 0;
    uint32_t meta = RVBI_HDR + RVBI_SEG * nseg + clen;
    if (meta > room) return 0;
    uint32_t c = crc32_update(0, p, 28);
    c = crc32_update(c, zero, 4);
    c = crc32_update(c, p + RVBI_HDR, meta - RVBI_HDR);
    if (c != hcrc || dsize > room - meta) return 0;
    *bytes = meta + dsize;
    return 1;
}

int bootbin_parse(const uint8_t *base, uint32_t size, struct bootbin *out, const char **why)
{
    out->bit = 0; out->bit_words = 0; out->img = 0; out->img_bytes = 0; out->nparts = 0;
    if (size < 0xa0) { *why = "too short for a boot header"; return -1; }
    if (w32(base + BH_WIDTH) != WIDTH_DETECT || w32(base + BH_ID) != ID_XNLX) {
        *why = "no boot header (0xaa995566, \"XNLX\" at 0x20)";
        return -1;
    }
    uint32_t it = w32(base + BH_IMG_TAB), pt = w32(base + BH_PART_TAB);
    if (it % 4 || pt % 4 || it > size - 8 || pt > size - PH_BYTES) {
        *why = "header table offsets out of range";
        return -1;
    }
    uint32_t n = w32(base + it + 4);
    if (n == 0 || n > MAX_PARTS || n > (size - pt) / PH_BYTES) { *why = "partition count out of range"; return -1; }
    for (uint32_t i = 0; i < n; i++) {
        const uint8_t *h = base + pt + PH_BYTES * i;
        uint32_t sum = 0;
        for (int k = 0; k < 15; k++) sum += w32(h + 4 * k);
        if (~sum != w32(h + 60)) { *why = "a partition header's checksum is wrong"; return -1; }
        uint32_t words = w32(h + 4), off = w32(h + 20), attr = w32(h + 24);
        if (off > size / 4 || words > size / 4 - off) { *why = "a partition lies past the end"; return -1; }
        const uint8_t *d = base + 4 * off;
        if ((attr & ATTR_DEST) == ATTR_DEST_PL) {
            if (!out->bit) { out->bit = (const uint32_t *)(const void *)d; out->bit_words = words; }
        } else if (!out->img && rvbi_ok(d, 4 * words, &out->img_bytes)) {
            out->img = d;
        }
    }
    out->nparts = n;
    if (!out->bit) { *why = "no bitstream (a partition for the PL)"; return -1; }
    if (!out->img) { *why = "no RISC-V image (a partition starting \"RVBI\" with a good header CRC)"; return -1; }
    return 0;
}
