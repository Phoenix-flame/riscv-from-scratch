// =====================================================================
// bsp.c  -  the small runtime declared in bsp.h
// ---------------------------------------------------------------------
// uart_init reads the clock frequency out of SYSCON rather than trusting
// a #define, so re-synthesising at a different PLL setting cannot leave
// the baud rate silently wrong.
// =====================================================================
#include "bsp.h"
#include <stdarg.h>

void uart_init(uint32_t baud)
{
    uint32_t clk = SYS_CLK_HZ;
    if (clk == 0) clk = 48000000u;                 // sane fallback
    UART_BAUD  = (clk + baud / 2) / baud;          // clocks per bit, rounded
    UART_CTRL  = UART_CTRL_TXEN | UART_CTRL_RXEN |
                 UART_CTRL_BITS(8) | UART_CTRL_PAR_NONE |
                 UART_CTRL_TXCLR | UART_CTRL_RXCLR;
    UART_IDLECFG = 12;
    UART_IE    = 0;
}

void uart_putc(char c)
{
    while (UART_STATUS & UART_ST_TXFULL) { }
    UART_RXTX = (uint8_t)c;
}

int uart_getc_nb(void)
{
    uint32_t v = UART_RXTX;                        // [8] = "the byte is real"
    return (v & 0x100u) ? (int)(v & 0xFFu) : -1;
}

char uart_getc(void)
{
    int c;
    while ((c = uart_getc_nb()) < 0) { }
    return (char)c;
}

void uart_puts(const char *s)
{
    while (*s) {
        if (*s == '\n') uart_putc('\r');
        uart_putc(*s++);
    }
}

void uart_flush(void)
{
    while (!(UART_STATUS & UART_ST_TXEMPTY) || (UART_STATUS & UART_ST_TXBUSY)) { }
}

// ---------------------------------------------------------------------
// A printf subset: %c %s %d %u %x %p %%, with an optional width, an
// optional '-' to left-align it and an optional '0' to pad with zeros
// (%08x, %-22s). Everything is written straight to the UART -- no
// buffer, no malloc, no float.
// ---------------------------------------------------------------------
static void put_uint(uint32_t v, uint32_t base, int width, char pad)
{
    char buf[11];
    int  n = 0;
    do {
        uint32_t d = v % base;
        buf[n++] = (char)(d < 10 ? '0' + d : 'a' + d - 10);
        v /= base;
    } while (v);
    while (n < width) buf[n++] = pad;
    while (n--) uart_putc(buf[n]);
}

void s6_printf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);

    for (; *fmt; fmt++) {
        if (*fmt != '%') {
            if (*fmt == '\n') uart_putc('\r');
            uart_putc(*fmt);
            continue;
        }
        fmt++;
        char pad   = ' ';
        int  left  = 0;
        int  width = 0;
        if (*fmt == '-') { left = 1; fmt++; }
        if (*fmt == '0') { pad = '0'; fmt++; }
        while (*fmt >= '0' && *fmt <= '9') width = width * 10 + (*fmt++ - '0');

        switch (*fmt) {
        case 'c': uart_putc((char)va_arg(ap, int)); break;
        case 's': {
            const char *s = va_arg(ap, const char *);
            int n = 0;
            while (s[n]) n++;
            if (!left) while (n < width) { uart_putc(' '); width--; }
            while (*s) uart_putc(*s++);
            if (left)  while (n < width) { uart_putc(' '); width--; }
            break;
        }
        case 'd': {
            int32_t v = va_arg(ap, int32_t);
            if (v < 0) { uart_putc('-'); put_uint((uint32_t)(-v), 10, width, pad); }
            else       { put_uint((uint32_t)v, 10, width, pad); }
            break;
        }
        case 'u': put_uint(va_arg(ap, uint32_t), 10, width, pad); break;
        case 'x': put_uint(va_arg(ap, uint32_t), 16, width, pad); break;
        case 'p': uart_puts("0x"); put_uint((uint32_t)va_arg(ap, void *), 16, 8, '0');
                  break;
        case '%': uart_putc('%'); break;
        default:  uart_putc('%'); uart_putc(*fmt); break;
        }
    }
    va_end(ap);
}

// ---------------------------------------------------------------------
// mtime is 64 bits behind a 32-bit bus, so the high half can tick between
// the two reads. Re-read the high half and retry if it moved.
// ---------------------------------------------------------------------
uint64_t mtime_get(void)
{
    uint32_t hi, lo, hi2;
    do {
        hi  = CLINT_MTIMEH;
        lo  = CLINT_MTIMEL;
        hi2 = CLINT_MTIMEH;
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

void delay_us(uint32_t us)
{
    uint64_t target = mtime_get() + us;            // mtime ticks once per us
    while (mtime_get() < target) { }
}

void halt(uint32_t code)
{
    uart_flush();
    SYS_TOHOST = code;
    for (;;) { }
}

// A default handler so a program that does not define one still links.
// An interrupt (mcause[31]) resumes exactly where it was; an exception
// steps over the faulting instruction -- which with the C extension means
// looking at the instruction to see whether it is 2 or 4 bytes long.
__attribute__((weak))
uint32_t trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval)
{
    (void)mtval;
    if (mcause & 0x80000000u) return mepc;
    return mepc + ((*(volatile uint16_t *)mepc & 3u) == 3u ? 4u : 2u);
}
