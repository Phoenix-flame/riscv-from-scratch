/* muldiv_demo.c - exercises RV32M (compiled with -march=rv32im, so the
 * compiler emits real mul/div/rem instructions instead of libgcc calls). */
#include "firmware.h"
#define RAM0 (*(volatile unsigned *)0x00000000)

int main(void)
{
    int a = -20, b = 6;
    unsigned f = 1;
    for (unsigned i = 1; i <= 6; i++) f = f * i;   /* 6! = 720, uses MUL */

    kprintf("6!         = %u\n", f);
    kprintf("%d * %d    = %d\n", a, b, a * b);      /* MUL  -> -120 */
    kprintf("%d / %d    = %d\n", a, b, a / b);      /* DIV  -> -3   */
    kprintf("%d %% %d    = %d\n", a, b, a % b);     /* REM  -> -2   */
    kprintf("0x%x * 0x%x hi = 0x%x\n", 0xFFFFFFFFu, 0xFFFFFFFFu,
            (unsigned)(((unsigned long long)0xFFFFFFFFu * 0xFFFFFFFFu) >> 32));

    RAM0 = f;        /* leave 720 for the testbench */
    halt(0);
}
