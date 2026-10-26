/* =====================================================================
 * bootimg.h  -  the boot image the ROM loads over the serial port
 * ---------------------------------------------------------------------
 * tools/rvboot builds one from any statically linked ELF: each PT_LOAD
 * program header becomes a segment (where it goes, how many bytes come
 * over the wire, how many it occupies -- the rest is .bss, zeroed), plus
 * the entry point, the privilege to enter it in, and a command line for
 * /chosen/bootargs. The stream, all little-endian:
 *
 *   struct rvbi_header        32 bytes
 *   struct rvbi_seg  [nseg]   12 bytes each
 *   char cmdline[cmdline_len] (no NUL)
 *   segment data, in order    filesz bytes each
 *
 * Two CRC-32s: hdr_crc covers the header (with hdr_crc itself as 0),
 * the segment table and the command line, and is checked BEFORE anything
 * is written to RAM -- so a garbled length or address is caught before it
 * can do damage; data_crc covers the segment data and is checked once it
 * has landed. The stream is one-way: no handshake, so any serial program
 * can send it (stty raw; cat image > /dev/ttyUSB0).
 * ===================================================================== */
#ifndef BOOTIMG_H
#define BOOTIMG_H

#include <stdint.h>

#define RVBI_MAGIC     0x49425652u      /* "RVBI" */
#define RVBI_VERSION   1
#define RVBI_MAX_SEGS  8
#define RVBI_MAX_CMD   255

#define RVBI_F_MMODE   (1u << 0)        /* enter in M-mode (no SBI) instead of S */

struct rvbi_header {
    uint32_t magic;
    uint16_t version;
    uint16_t nseg;
    uint32_t entry;
    uint32_t flags;
    uint16_t cmdline_len;
    uint16_t reserved;
    uint32_t data_size;                 /* sum of filesz: what follows the cmdline */
    uint32_t data_crc;
    uint32_t hdr_crc;
};

struct rvbi_seg {
    uint32_t addr;                      /* physical load address */
    uint32_t filesz;                    /* bytes in the stream */
    uint32_t memsz;                     /* bytes in memory (>= filesz; tail zeroed) */
};

#endif
