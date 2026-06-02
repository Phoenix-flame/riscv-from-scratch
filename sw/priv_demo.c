/* priv_demo.c - machine mode sets up, drops to USER mode, and a user-mode
 * program makes syscalls (ecall) and gets blocked when it tries a
 * privileged instruction. */
#include "firmware.h"

extern void ptrap_entry(void);

#define SYS_PUTC 1
#define SYS_EXIT 2
static inline long syscall1(long num, long arg){
    register long a0 asm("a0") = arg;
    register long a7 asm("a7") = num;
    asm volatile ("ecall" : "+r"(a0) : "r"(a7) : "memory");
    return a0;
}
static void uputs(const char *s){ while(*s) syscall1(SYS_PUTC,(unsigned char)*s++); }

/* ---- runs in USER mode ---- */
void user_main(void){
    uputs("user: hello from U-mode (printed via ecall syscalls)\n");
    uputs("user: now trying a privileged CSR read...\n");
    unsigned x;
    asm volatile ("csrr %0, mstatus" : "=r"(x));   /* ILLEGAL in U-mode -> traps */
    (void)x;
    uputs("user: survived (kernel skipped the blocked op), exiting\n");
    syscall1(SYS_EXIT, 0);
    for(;;){}
}

/* drop to user mode: MPP=U, mepc=entry, mret */
static void enter_user(void (*entry)(void)){
    unsigned ms;
    asm volatile ("csrr %0, mstatus" : "=r"(ms));
    ms &= ~(3u << 11);                       /* MPP = 00 (user) */
    asm volatile ("csrw mstatus, %0" :: "r"(ms));
    asm volatile ("csrw mepc, %0"   :: "r"(entry));
    asm volatile ("mret");                    /* -> user mode at entry */
}

/* ---- runs in MACHINE mode ---- */
int main(void){
    asm volatile ("csrw mtvec, %0" :: "r"((unsigned)&ptrap_entry));
    kprintf("kernel: configured trap vector, dropping to user mode\n");
    enter_user(user_main);
    return 0;   /* unreachable */
}
