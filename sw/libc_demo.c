/* =====================================================================
 * libc_demo.c  -  Real picolibc: full printf + malloc/free on the core.
 * ---------------------------------------------------------------------
 * Replaces the hand-rolled mini-printf (Step 13) and the FreeRTOS header
 * shims with a genuine C library. Everything here -- formatted output,
 * heap allocation, string functions -- is picolibc code compiled for
 * rv32im and linked against the UART/heap retarget layer.
 * ===================================================================== */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void)
{
    printf("picolibc on rv32im: printf + malloc\n");
    printf("int=%d uint=%u hex=0x%08x char=%c\n", -42, 42u, 0xDEADBEEFu, 'Q');
    printf("width=[%5d][%-5d][%05d]\n", 7, 7, 7);

    int *a = malloc(8 * sizeof(int));
    for (int i = 0; i < 8; i++) a[i] = i * i;
    int sum = 0;
    for (int i = 0; i < 8; i++) sum += a[i];
    printf("squares sum=%d\n", sum);            /* 140 */

    char *s = malloc(32);
    strcpy(s, "hello, ");
    strcat(s, "world");
    printf("str='%s' len=%u\n", s, (unsigned)strlen(s));

    free(a);
    free(s);
    void *b = malloc(64);                        /* heap reuse after free */
    printf("reuse ptr nonnull=%d\n", b != NULL);
    free(b);

    printf("DONE\n");
    return 0;
}
