/* =====================================================================
 * soc_demo.c  -  Uses the freestanding mini-library (firmware.h) for
 * printf/snprintf-style output over the UART. No host libc needed.
 * ===================================================================== */
#include "firmware.h"

#define RAM0 (*(volatile unsigned int *)0x00000000)

int main(void)
{
    char buffer[100];

    ksnprintf(buffer, sizeof buffer, "Test %02d", 5);
    kprintf("%s\n", buffer);

    kprintf("Hello World from my custom risc-v processor ...\n");
    kprintf("formatting: dec=%d  uns=%u  hex=0x%08x  char=%c\n",
            -42, 1234u, 0xCAFE, '!');

    unsigned t0 = TIMER;
    for (volatile int i = 0; i < 5; i++) { /* burn cycles */ }
    unsigned t1 = TIMER;

    RAM0 = t1 - t0;
    kprintf("loop took %u timer cycles\n", t1 - t0);

    halt(0);            /* SYSCON write -> stop simulation */
}
