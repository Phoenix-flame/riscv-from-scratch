/* =====================================================================
 * sbi_libc.c  -  bind picolibc to the SBI instead of to a UART
 * ---------------------------------------------------------------------
 * Step 37's retarget (sw/picolibc_retarget.c) wrote the UART registers
 * at a hardcoded address and halted through SYSCON. A program loaded by
 * the boot ROM runs in S-mode on whatever machine it finds, so here
 * stdout is the SBI debug console and _exit is SBI system_reset: the
 * same libc_demo.c source then runs unchanged on this platform -- or on
 * anything else with an SBI under it.
 * ===================================================================== */
#include <stdio.h>
#include <unistd.h>
#include "sbi.h"

static int sbi_stdout_putc(char c, FILE *file)
{
    (void)file;
    if (c == '\n') sbi_putchar('\r');
    sbi_putchar(c);
    return c;
}

static FILE __stdio = FDEV_SETUP_STREAM(sbi_stdout_putc, NULL, NULL, _FDEV_SETUP_WRITE);
FILE *const stdout = &__stdio;
FILE *const stderr = &__stdio;

void _exit(int code)
{
    sbi_system_reset(SBI_SRST_SHUTDOWN, code ? SBI_SRST_REASON_FAILURE : SBI_SRST_REASON_NONE);
    for (;;) { }
}
