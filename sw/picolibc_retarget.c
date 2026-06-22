/* =====================================================================
 * picolibc_retarget.c  -  Bind picolibc to this SoC's UART and SYSCON
 * ---------------------------------------------------------------------
 * picolibc's printf writes through `stdout`, an ordinary FILE whose `put`
 * callback we supply; here it polls the memory-mapped UART and emits a
 * byte. malloc needs no code -- picolibc's own sbrk walks the heap region
 * the linker script bounds with __heap_start/__heap_end. _exit halts.
 *
 * The UART poll (STATUS bit0 = ready) means the exact same object works on
 * the simulation UART (always ready, prints via $write) and the real
 * synthesizable uart_hw (which actually goes busy while serializing).
 * ===================================================================== */
#include <stdio.h>
#include <unistd.h>

#define UART_TX     (*(volatile unsigned int *)0x10000000u)
#define UART_STATUS (*(volatile unsigned int *)0x10000004u)
#define SYSCON      (*(volatile unsigned int *)0x20000000u)

static int uart_putc(char c, FILE *file)
{
    (void)file;
    if (c == '\n') {                       /* cook LF -> CRLF */
        while (!(UART_STATUS & 1u)) { }
        UART_TX = (unsigned)'\r';
    }
    while (!(UART_STATUS & 1u)) { }
    UART_TX = (unsigned char)c;
    return c;
}

static FILE __stdio = FDEV_SETUP_STREAM(uart_putc, NULL, NULL, _FDEV_SETUP_WRITE);
FILE *const stdout = &__stdio;
FILE *const stderr = &__stdio;

void _exit(int code)
{
    (void)code;
    SYSCON = (unsigned)code;
    for (;;) { }
}
