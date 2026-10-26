/* =====================================================================
 * ns16550.h  -  polled driver for a 16550-compatible UART
 * ---------------------------------------------------------------------
 * Parameterised exactly as a device-tree node describes the device:
 * base address, reg-shift (register stride = 1 << shift) and
 * reg-io-width (1 or 4 byte accesses). The ROM fills these in from its
 * own platform.h; a payload fills them in from the DT it was handed.
 * ===================================================================== */
#ifndef NS16550_H
#define NS16550_H

#include <stdint.h>

struct ns16550 {
    uintptr_t base;
    int       shift;
    int       io_width;
};

void ns16550_init(const struct ns16550 *u, unsigned divisor);   /* 8N1, FIFOs on */
void ns16550_putc(const struct ns16550 *u, int c);
int  ns16550_getc(const struct ns16550 *u);                     /* -1: nothing waiting */
int  ns16550_lsr(const struct ns16550 *u);                      /* reading clears OE/PE/FE */
int  ns16550_rbr(const struct ns16550 *u);                      /* pop, without looking */
void ns16550_flush(const struct ns16550 *u);                    /* until the line is idle */
/* interrupt when `trigger` (1, 4, 8, 14) bytes are waiting, or on a receive timeout */
void ns16550_rx_irq(const struct ns16550 *u, int trigger);

#define UART_LSR_DR    0x01
#define UART_LSR_OE    0x02
#define UART_LSR_PE    0x04
#define UART_LSR_FE    0x08
#define UART_LSR_THRE  0x20
#define UART_LSR_TEMT  0x40

#endif
