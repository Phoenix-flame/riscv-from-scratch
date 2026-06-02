/* ecall_demo.c - make system calls via ecall, serviced by trap_handler.S */
#include "firmware.h"

extern void trap_entry(void);          /* from trap_handler.S */

#define SYS_PUTC 1
#define SYS_EXIT 2

static inline long syscall1(long num, long arg)
{
    register long a0 asm("a0") = arg;
    register long a7 asm("a7") = num;
    asm volatile ("ecall" : "+r"(a0) : "r"(a7) : "memory");
    return a0;
}

int main(void)
{
    /* install the trap vector */
    asm volatile ("csrw mtvec, %0" :: "r"((unsigned)&trap_entry));

    const char *msg = "hello via ecall syscalls!\n";
    for (int i = 0; msg[i]; i++)
        syscall1(SYS_PUTC, (unsigned char)msg[i]);   /* user -> kernel -> UART */

    syscall1(SYS_EXIT, 0);                            /* halt via syscall */
    for (;;) { }
}
