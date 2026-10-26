/* =====================================================================
 * lib.h  -  the little C library the boot ROM and its payloads share
 * ---------------------------------------------------------------------
 * Freestanding: string/memory helpers (GCC may also emit calls to
 * memcpy/memset on its own), CRC-32, and a printf that writes through
 * whatever putc the program installs -- the ROM's is the UART, a
 * payload's is the SBI console.
 * ===================================================================== */
#ifndef BOOT_LIB_H
#define BOOT_LIB_H

#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

void  *memcpy(void *d, const void *s, size_t n);
void  *memmove(void *d, const void *s, size_t n);
void  *memset(void *d, int c, size_t n);
int    memcmp(const void *a, const void *b, size_t n);
void  *memchr(const void *s, int c, size_t n);
size_t strlen(const char *s);
int    strcmp(const char *a, const char *b);
int    strncmp(const char *a, const char *b, size_t n);
char  *strstr(const char *h, const char *n);

/* CRC-32 (IEEE 802.3, as zlib / Python's binascii.crc32): crc32(0, ...) to start */
uint32_t crc32(uint32_t crc, const void *buf, size_t n);
uint32_t crc32_byte(uint32_t crc, uint8_t b);      /* running form, pre/post-inverted */

/* printf: %c %s %d %u %x %X %p %%, flags '-' '0', a width; 'l' is accepted */
extern void (*lib_putc)(int c);                    /* set by the program; LF -> CRLF */
void printf(const char *fmt, ...);
void vprintf(const char *fmt, va_list ap);
void puts_raw(const char *s);                      /* no newline added */

#endif
