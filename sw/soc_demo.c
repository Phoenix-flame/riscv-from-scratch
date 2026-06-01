/* =====================================================================
 * soc_demo.c  -  Drive the memory-mapped peripherals from C.
 * ---------------------------------------------------------------------
 * Prints a message over the UART, measures a span of timer cycles, and
 * halts the simulation through the syscon device. Uses only character
 * literals (no string constants), so it needs no preloaded .rodata --
 * see the note in docs/10-running-c.md about initialized data.
 * ===================================================================== */

#define UART_TX  (*(volatile unsigned char *)0x10000000)
#define TIMER    (*(volatile unsigned int  *)0x10010000)  /* MTIME */
#define SYSCON   (*(volatile unsigned int  *)0x20000000)  /* halt  */
#define RAM0     (*(volatile unsigned int  *)0x00000000)

static void uart_putc(char c) { UART_TX = (unsigned char)c; }

int main(void)
{
    /* "RV32I OK\n" one character at a time */
    uart_putc('R'); uart_putc('V'); uart_putc('3'); uart_putc('2');
    uart_putc('I'); uart_putc(' '); uart_putc('O'); uart_putc('K');
    uart_putc('\n');

    /* Measure how many cycles a tiny loop takes, using the timer. */
    unsigned t0 = TIMER;
    for (volatile int i = 0; i < 5; i++) { /* burn some cycles */ }
    unsigned t1 = TIMER;

    RAM0 = t1 - t0;        /* leave the measured delta in RAM for the TB */

    SYSCON = 0;            /* stop the simulation, exit code 0 */
    for (;;) { }           /* unreachable */
}
