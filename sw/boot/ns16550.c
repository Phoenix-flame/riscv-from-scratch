/* =====================================================================
 * ns16550.c  -  see ns16550.h
 * ===================================================================== */
#include "ns16550.h"

enum { RBR = 0, THR = 0, DLL = 0, IER = 1, DLM = 1, FCR = 2, LCR = 3, MCR = 4, LSR = 5 };

static unsigned rd(const struct ns16550 *u, int r)
{
    uintptr_t a = u->base + ((uintptr_t)r << u->shift);
    return u->io_width == 4 ? *(volatile uint32_t *)a & 0xffu : *(volatile uint8_t *)a;
}

static void wr(const struct ns16550 *u, int r, unsigned v)
{
    uintptr_t a = u->base + ((uintptr_t)r << u->shift);
    if (u->io_width == 4) *(volatile uint32_t *)a = v;
    else                  *(volatile uint8_t *)a = (uint8_t)v;
}

void ns16550_init(const struct ns16550 *u, unsigned divisor)
{
    wr(u, IER, 0x00);                   /* polled: no interrupts */
    wr(u, LCR, 0x80);                   /* DLAB: the divisor latch */
    wr(u, DLL, divisor & 0xff);
    wr(u, DLM, (divisor >> 8) & 0xff);
    wr(u, LCR, 0x03);                   /* 8 data bits, no parity, 1 stop */
    wr(u, FCR, 0x07);                   /* FIFOs on, both cleared */
    wr(u, MCR, 0x03);                   /* DTR, RTS */
}

void ns16550_putc(const struct ns16550 *u, int c)
{
    while (!(rd(u, LSR) & UART_LSR_THRE)) { }
    wr(u, THR, (unsigned)c & 0xff);
}

int ns16550_getc(const struct ns16550 *u)
{
    return (rd(u, LSR) & UART_LSR_DR) ? (int)rd(u, RBR) : -1;
}

int ns16550_lsr(const struct ns16550 *u) { return (int)rd(u, LSR); }
int ns16550_rbr(const struct ns16550 *u) { return (int)rd(u, RBR); }

void ns16550_flush(const struct ns16550 *u)
{
    while (!(rd(u, LSR) & UART_LSR_TEMT)) { }
}

void ns16550_rx_irq(const struct ns16550 *u, int trigger)
{
    unsigned t = trigger >= 14 ? 3 : trigger >= 8 ? 2 : trigger >= 4 ? 1 : 0;
    wr(u, FCR, 0x01 | (t << 6));        /* FIFOs on (kept), trigger level */
    wr(u, IER, 0x01);                   /* received data available / timeout */
}
