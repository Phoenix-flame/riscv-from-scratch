/* =====================================================================
 * firmware.h  -  Tiny freestanding "board support" library for the SoC.
 * ---------------------------------------------------------------------
 * No host libc is available (the toolchain ships no newlib), so we
 * provide just what we need: memory-mapped device handles, a few string
 * helpers, and a small printf/snprintf that sends bytes to the UART.
 * ===================================================================== */
#ifndef FIRMWARE_H
#define FIRMWARE_H

#include <stdarg.h>     /* a COMPILER header, available without a libc */

/* ---- Memory-mapped devices (see rtl/soc.v) ---- */
#define UART_TX  (*(volatile unsigned char *)0x10000000)
#define UART_ST  (*(volatile unsigned int  *)0x10000004)
#define TIMER    (*(volatile unsigned int  *)0x10010000)  /* MTIME   */
#define SYSCON   (*(volatile unsigned int  *)0x20000000)  /* halt    */

/* ---- Minimal string/memory helpers ---- */
unsigned strlen(const char *s);
void    *memset(void *dst, int c, unsigned n);
void    *memcpy(void *dst, const void *src, unsigned n);

/* ---- UART + formatted output ---- */
void uart_putc(char c);
void uart_puts(const char *s);                 /* NUL-terminated */
void kprintf(const char *fmt, ...);            /* prints to the UART */
int  ksnprintf(char *buf, int cap, const char *fmt, ...);

/* ---- Convenience ---- */
static inline void halt(int code) { SYSCON = (unsigned)code; for (;;) {} }

#endif
