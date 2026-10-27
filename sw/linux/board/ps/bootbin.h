/* =====================================================================
 * bootbin.h  -  finding riscv_linux's two payloads in a BOOT.BIN (Step 56)
 * ---------------------------------------------------------------------
 * BOOT.BIN is the Zynq BootROM's container (UG585 6.3, UG821): a boot
 * header, an image header table and a partition header table, then the
 * partitions. The BootROM itself only loads the first one, the FSBL --
 * this program. The FSBL finds the rest:
 *
 *   - the bitstream: the partition whose destination is the PL. mkbootimage
 *     and bootgen both store it with each 32-bit word byte-swapped, so it
 *     goes to PCAP as it is;
 *   - the RISC-V's image: the first partition that starts with "RVBI"
 *     and whose header CRC checks (sw/boot/bootimg.h).
 *
 * bootbin_parse() reads only what it is given (a flash map, or a buffer
 * received over the UART) and checks every offset against its size.
 * ===================================================================== */
#ifndef BOOTBIN_H
#define BOOTBIN_H
#include <stdint.h>

struct bootbin {
    const uint32_t *bit;        /* the PL partition, word-aligned */
    uint32_t bit_words;
    const uint8_t *img;         /* the RVBI image */
    uint32_t img_bytes;         /* its own size: header, table, cmdline, data */
    uint32_t nparts;
};

/* 0 when both payloads are there; otherwise -1 and *why says what is wrong */
int bootbin_parse(const uint8_t *base, uint32_t size, struct bootbin *out, const char **why);

/* the CRC-32 of zlib, Python's binascii.crc32 and the ROM; crc = 0 to start */
uint32_t crc32_update(uint32_t crc, const uint8_t *p, uint32_t n);

#endif
