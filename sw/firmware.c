/* =====================================================================
 * firmware.c  -  Implementation of the tiny freestanding library.
 * ---------------------------------------------------------------------
 * A shared formatting core (kvprintf) drives two "sinks": the UART (for
 * kprintf) and a caller buffer (for ksnprintf). Supports %c %s %d %u
 * %x %X %% with optional field width and '0' padding (e.g. %02d, %08x).
 * Decimal conversion uses / and % by 10, resolved by libgcc's software
 * routines (this core has no hardware multiply/divide).
 * ===================================================================== */
#include "firmware.h"

/* ---- string/memory helpers ---- */
unsigned strlen(const char *s)         { unsigned n = 0; while (s[n]) n++; return n; }
void    *memset(void *d, int c, unsigned n) { unsigned char *p = d; while (n--) *p++ = (unsigned char)c; return d; }
void    *memcpy(void *d, const void *s, unsigned n) { unsigned char *a = d; const unsigned char *b = s; while (n--) *a++ = *b++; return d; }

/* ---- UART primitives ---- */
void uart_putc(char c)        { UART_TX = (unsigned char)c; }
void uart_puts(const char *s) { while (*s) uart_putc(*s++); }

/* ---- formatting core ---- */
typedef void (*sink_fn)(void *ctx, char c);

static void emit_str(sink_fn put, void *ctx, const char *s)
{
    if (!s) s = "(null)";
    while (*s) put(ctx, *s++);
}

static void emit_uint(sink_fn put, void *ctx, unsigned val,
                      unsigned base, int width, char pad, int upper)
{
    char tmp[32];
    int  n = 0;
    const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";

    if (val == 0) tmp[n++] = '0';
    while (val) { tmp[n++] = digits[val % base]; val /= base; }

    for (int i = n; i < width; i++) put(ctx, pad);   /* left-pad */
    while (n) put(ctx, tmp[--n]);                     /* digits, MSB first */
}

static void kvprintf(sink_fn put, void *ctx, const char *fmt, va_list ap)
{
    for (; *fmt; fmt++) {
        if (*fmt != '%') { put(ctx, *fmt); continue; }
        fmt++;

        char pad = ' ';
        int  width = 0;
        if (*fmt == '0') { pad = '0'; fmt++; }
        while (*fmt >= '0' && *fmt <= '9') { width = width * 10 + (*fmt - '0'); fmt++; }

        switch (*fmt) {
            case 'c': put(ctx, (char)va_arg(ap, int)); break;
            case 's': emit_str(put, ctx, va_arg(ap, const char *)); break;
            case 'u': emit_uint(put, ctx, va_arg(ap, unsigned), 10, width, pad, 0); break;
            case 'x': emit_uint(put, ctx, va_arg(ap, unsigned), 16, width, pad, 0); break;
            case 'X': emit_uint(put, ctx, va_arg(ap, unsigned), 16, width, pad, 1); break;
            case 'd': {
                int v = va_arg(ap, int);
                if (v < 0) { put(ctx, '-'); emit_uint(put, ctx, (unsigned)(-v), 10,
                                                       width > 0 ? width - 1 : 0, pad, 0); }
                else        emit_uint(put, ctx, (unsigned)v, 10, width, pad, 0);
                break;
            }
            case '%': put(ctx, '%'); break;
            case '\0': return;
            default:  put(ctx, '%'); put(ctx, *fmt); break;
        }
    }
}

/* ---- sink: UART ---- */
static void sink_uart(void *ctx, char c) { (void)ctx; uart_putc(c); }

void kprintf(const char *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    kvprintf(sink_uart, 0, fmt, ap);
    va_end(ap);
}

/* ---- sink: caller buffer ---- */
typedef struct { char *buf; int cap; int len; } bufsink;

static void sink_buf(void *ctx, char c)
{
    bufsink *b = (bufsink *)ctx;
    if (b->len < b->cap - 1) b->buf[b->len] = c;
    b->len++;
}

int ksnprintf(char *buf, int cap, const char *fmt, ...)
{
    bufsink b = { buf, cap, 0 };
    va_list ap; va_start(ap, fmt);
    kvprintf(sink_buf, &b, fmt, ap);
    va_end(ap);
    if (cap > 0) buf[b.len < cap ? b.len : cap - 1] = '\0';
    return b.len;
}
