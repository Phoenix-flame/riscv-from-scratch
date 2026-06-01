/* =====================================================================
 * sum.c  -  A small C program for the bare-metal RV32I core.
 * ---------------------------------------------------------------------
 * Computes 1 + 2 + ... + n in a helper function (so the call exercises
 * the stack and the calling convention) and returns it from main().
 * crt0.s stores the return value to data memory address 0, where the
 * testbench checks it.
 *
 * Note: no <stdio.h>, no printf -- there is no operating system or libc.
 * The program is pure computation; "output" means leaving a value in a
 * register or memory.
 * ===================================================================== */

int sum_to(int n)
{
    int sum = 0;
    for (int i = 1; i <= n; i++)
        sum += i;
    return sum;
}

int main(void)
{
    return sum_to(10);   /* 55 */
}
