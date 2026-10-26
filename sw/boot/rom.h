/* =====================================================================
 * rom.h  -  what the boot ROM's two halves (loader, SBI) share
 * ===================================================================== */
#ifndef ROM_H
#define ROM_H

#include <stdint.h>
#include "ns16550.h"
#include "platform.h"

#define csr_read(csr)      ({ uint32_t v_; __asm__ volatile("csrr %0, " #csr : "=r"(v_)); v_; })
#define csr_write(csr, v)  __asm__ volatile("csrw " #csr ", %0" :: "rK"(v))
#define csr_set(csr, v)    __asm__ volatile("csrs " #csr ", %0" :: "rK"(v))
#define csr_clear(csr, v)  __asm__ volatile("csrc " #csr ", %0" :: "rK"(v))

#define MIP_STIP  (1u << 5)
#define MIP_MTIP  (1u << 7)

extern const struct ns16550 rom_uart;
extern uint32_t ram_size;                  /* probed at boot */

uint64_t rdtime(void);
void fw_poweroff(int code);                /* 0 = pass; never returns */
void fw_reset(void);                       /* warm reset through the test device */
void rom_fail(int code);                   /* rom_start.S */

/* the payload area: RAM minus the firmware below it and the DTB above */
#define PAYLOAD_BASE  (RAM_BASE + FW_RAM_SIZE)
#define DTB_ADDR      (RAM_BASE + ram_size - DTB_AREA)

#endif
