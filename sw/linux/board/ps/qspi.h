/* =====================================================================
 * qspi.h  -  the Mitra's 16 MiB QSPI flash, from the PS (Step 56)
 * ---------------------------------------------------------------------
 * Reading is the controller's linear mode: the flash appears at
 * 0xfc00_0000 and plain loads read it. Writing is its I/O mode, one SPI
 * NOR command at a time: write enable, 64 KiB block erase, page program,
 * all with the commands every 3-byte-address SPI NOR flash takes.
 * ===================================================================== */
#ifndef QSPI_H
#define QSPI_H
#include <stdint.h>

#define QSPI_FLASH_BYTES  UINT32_C(0x01000000)

/* linear mode on; returns where the flash is mapped */
const uint8_t *qspi_map(void);

/* the JEDEC ID: manufacturer << 16 | type << 8 | capacity (0x18 = 16 MiB) */
uint32_t qspi_jedec_id(void);

/* erase what it needs, program n bytes at flash offset 0, read them back.
 * 0 on success, else -1 and *why. progress(done, n) after every 64 KiB.
 * Leaves the controller in linear mode. */
int qspi_write(const uint8_t *src, uint32_t n, void (*progress)(uint32_t, uint32_t), const char **why);

#endif
