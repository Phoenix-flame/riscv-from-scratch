/* =====================================================================
 * lib.c  -  see lib.h
 * ===================================================================== */
#include "lib.h"

void *memcpy(void *d, const void *s, size_t n)
{
    uint8_t *a = d; const uint8_t *b = s;
    if ((((uintptr_t)a | (uintptr_t)b | n) & 3) == 0)          /* word copy when aligned */
        for (; n; n -= 4, a += 4, b += 4) *(uint32_t *)a = *(const uint32_t *)b;
    else
        while (n--) *a++ = *b++;
    return d;
}

void *memmove(void *d, const void *s, size_t n)
{
    uint8_t *a = d; const uint8_t *b = s;
    if (a <= b || a >= b + n) return memcpy(d, s, n);
    while (n--) a[n] = b[n];                                    /* overlapping, backwards */
    return d;
}

void *memset(void *d, int c, size_t n)
{
    uint8_t *p = d;
    while (n--) *p++ = (uint8_t)c;
    return d;
}

int memcmp(const void *a, const void *b, size_t n)
{
    const uint8_t *x = a, *y = b;
    for (; n; n--, x++, y++) if (*x != *y) return *x - *y;
    return 0;
}

void *memchr(const void *s, int c, size_t n)
{
    const uint8_t *p = s;
    for (; n; n--, p++) if (*p == (uint8_t)c) return (void *)p;
    return 0;
}

size_t strlen(const char *s) { size_t n = 0; while (s[n]) n++; return n; }

int strcmp(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return (uint8_t)*a - (uint8_t)*b;
}

int strncmp(const char *a, const char *b, size_t n)
{
    for (; n; n--, a++, b++) {
        if (*a != *b) return (uint8_t)*a - (uint8_t)*b;
        if (!*a) return 0;
    }
    return 0;
}

char *strstr(const char *h, const char *n)
{
    size_t l = strlen(n);
    for (; *h; h++) if (strncmp(h, n, l) == 0) return (char *)h;
    return l ? 0 : (char *)h;
}

uint32_t crc32(uint32_t crc, const void *buf, size_t n)
{
    const uint8_t *p = buf;
    crc = ~crc;
    while (n--) crc = crc32_byte(crc, *p++);
    return ~crc;
}

/* ---- printf ---------------------------------------------------------- */
void (*lib_putc)(int c);

static void out(int c)
{
    if (c == '\n') lib_putc('\r');
    lib_putc(c);
}

void puts_raw(const char *s) { while (*s) out(*s++); }

static void out_num(uint32_t v, int base, int upper, int neg, int width, int zero, int left)
{
    char buf[12];
    const char *dig = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    int n = 0;
    do { buf[n++] = dig[v % base]; v /= base; } while (v);
    int len = n + neg;
    if (neg && zero) out('-');
    if (!left) for (; len < width; width--) out(zero ? '0' : ' ');
    if (neg && !zero) out('-');
    while (n) out(buf[--n]);
    if (left) for (; len < width; width--) out(' ');
}

void vprintf(const char *fmt, va_list ap)
{
    for (; *fmt; fmt++) {
        if (*fmt != '%') { out(*fmt); continue; }
        int left = 0, zero = 0, width = 0;
        fmt++;
        for (;; fmt++) {
            if (*fmt == '-') left = 1;
            else if (*fmt == '0') zero = 1;
            else break;
        }
        while (*fmt >= '0' && *fmt <= '9') width = width * 10 + (*fmt++ - '0');
        while (*fmt == 'l') fmt++;
        switch (*fmt) {
        case 'c': out(va_arg(ap, int)); break;
        case 's': {
            const char *s = va_arg(ap, const char *);
            int len = (int)strlen(s);
            if (!left) for (; len < width; width--) out(' ');
            puts_raw(s);
            if (left) for (; len < width; width--) out(' ');
            break;
        }
        case 'd': {
            int v = va_arg(ap, int);
            out_num(v < 0 ? -(uint32_t)v : (uint32_t)v, 10, 0, v < 0, width, zero, left);
            break;
        }
        case 'u': out_num(va_arg(ap, uint32_t), 10, 0, 0, width, zero, left); break;
        case 'x': out_num(va_arg(ap, uint32_t), 16, 0, 0, width, zero, left); break;
        case 'X': out_num(va_arg(ap, uint32_t), 16, 1, 0, width, zero, left); break;
        case 'p': out('0'); out('x'); out_num((uint32_t)va_arg(ap, void *), 16, 0, 0, 8, 1, 0); break;
        case '%': out('%'); break;
        default:  out('%'); if (*fmt) out(*fmt); else fmt--; break;
        }
    }
}

void printf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
}
