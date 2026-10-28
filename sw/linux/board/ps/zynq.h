/* =====================================================================
 * zynq.h  -  the few Zynq-7000 PS registers the riscv_linux PS program uses
 * ---------------------------------------------------------------------
 * Every register access goes through hw_rd()/hw_wr(), so the parts that
 * can be checked off the board (bootbin.c, qspi.c) build on a PC against
 * a model instead (test/, PS_HOST_TEST). Numbers from UG585, appendix B.
 * ===================================================================== */
#ifndef ZYNQ_H
#define ZYNQ_H
#include <stdint.h>

#ifdef PS_HOST_TEST
uint32_t hw_rd(uint32_t a);
void hw_wr(uint32_t a, uint32_t v);
#else
static inline uint32_t hw_rd(uint32_t a) { return *(volatile uint32_t *)(uintptr_t)a; }
static inline void hw_wr(uint32_t a, uint32_t v) { *(volatile uint32_t *)(uintptr_t)a = v; }
#endif

/* SLCR */
#define SLCR_LOCK        UINT32_C(0xf8000004)   /* write 0x767b */
#define SLCR_UNLOCK      UINT32_C(0xf8000008)   /* write 0xdf0d */
#define SLCR_FPGA_RST    UINT32_C(0xf8000240)   /* FCLK resets, 1 = asserted */
#define SLCR_BOOT_MODE   UINT32_C(0xf800025c)   /* [2:0]: 0 JTAG, 1 QSPI, 5 SD */
#define SLCR_LVL_SHFTR   UINT32_C(0xf8000900)   /* PS<->PL level shifters */
#define SLCR_FPGA1_CLK   UINT32_C(0xf8000180)   /* FCLK1: [25:20] DIVISOR1, [13:8] DIVISOR0, [5:4] 0 = IO PLL */
#define BOOT_MODE_JTAG   0
#define BOOT_MODE_QSPI   1

/* UART0, the on-board CH340 */
#define UART0            UINT32_C(0xe0000000)
#define UART_SR          (UART0 + 0x2c)        /* bit 1 RX empty, bit 4 TX full */
#define UART_FIFO        (UART0 + 0x30)

#endif
