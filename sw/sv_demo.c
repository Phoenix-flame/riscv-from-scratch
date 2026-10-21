/* sv_demo.c - Step 44: an S-mode kernel, running TRANSLATED, that handles
 * its user program's page faults itself (the shape xv6 needs).
 *
 *   M  (this file, main)  builds one Sv32 address space, delegates the U
 *      ecall and all three page-fault causes to S (medeleg 8/12/13/15),
 *      turns translation on and drops to S. Afterwards M only ever sees the
 *      S kernel's "shutdown" ecall (cause 9, not delegated).
 *   S  (s_main + s_trap)  runs with translation on, on kernel-only pages.
 *      It shows SUM: reading a user page faults until SUM is set (the fault
 *      is taken from S to S). Then it runs the user program and serves it:
 *      putchar/exit ecalls, a DEMAND-PAGED store (map the page, sfence.vma,
 *      retry), and finally a fetch fault (kill the task, shut down).
 *   U  (tlb-style .utext in sv_asm.S)  linked at PA 0x1000, run at VA 0x3000.
 *
 * Address space (VA -> PA, perms; "S" = kernel-only, U=0):
 *   0x0000 -> 0x0000  R W X  S   kernel code (ROM) + stack (RAM)
 *   0x3000 -> 0x1000  X      U   user code
 *   0x4000 -> 0x4000  R W    U   user data
 *   0x5000    (unmapped)         demand-paged by S -> PA 0x5000
 *   0x6000 -> 0x4000  R W    U   same data page, NOT executable
 *   0x7000 -> 0x7000  R W    S   kernel mailbox / save area
 *   0x8000, 0x9000 identity  S   the page tables themselves (S edits them)
 *   0x10000000 (4 MiB) UART  R W S
 * Results go to the mailbox at 0x7F00 (see sv_asm.S). No .rodata/.data. */

#define ROOT  0x8000u
#define L0    0x9000u
#define PV 1u
#define PR 2u
#define PW 4u
#define PX 8u
#define PU 16u
#define LEAF(pa, f) ((((pa) >> 12) << 10) | (f))

extern void m_trap(void);
extern void s_trap(void);
extern unsigned s_probe_user(void);       /* lw 0x4000, or 0 if it faulted */
extern void s_enter_user(unsigned va);
extern void s_shutdown(void);

#define MBOX ((volatile unsigned *)0x7F00u)
#define UART_TX (*(volatile unsigned *)0x10000000u)
#define UART_ST (*(volatile unsigned *)0x10000004u)
static void kputc(char c){ while (!(UART_ST & 1u)) { } UART_TX = (unsigned char)c; }

/* ---- S-mode kernel (runs translated) ---- */
void s_main(void)
{
    kputc('S'); kputc(':');
    MBOX[0] = s_probe_user();                         /* SUM=0: faults -> 0  */
    asm volatile ("csrs sstatus, %0" :: "r"(1u << 18)); /* SUM = 1             */
    MBOX[1] = s_probe_user();                         /* now reads the page  */
    asm volatile ("csrc sstatus, %0" :: "r"(1u << 18)); /* SUM = 0 again       */
    s_enter_user(0x3000u);                            /* never returns       */
}

/* ---- machine-mode boot ---- */
int main(void)
{
    volatile unsigned *root = (volatile unsigned *)ROOT;
    volatile unsigned *l0   = (volatile unsigned *)L0;
    unsigned ms;

    root[0]    = LEAF(L0, PV);                        /* VA 0..4 MiB -> L0  */
    root[0x40] = (0x40u << 20) | PV|PR|PW;            /* UART, kernel-only  */
    l0[0] = LEAF(0x0000u, PV|PR|PW|PX);               /* kernel             */
    l0[3] = LEAF(0x1000u, PV|PX|PU);                  /* user code          */
    l0[4] = LEAF(0x4000u, PV|PR|PW|PU);               /* user data          */
    l0[6] = LEAF(0x4000u, PV|PR|PW|PU);               /* ... not executable */
    l0[7] = LEAF(0x7000u, PV|PR|PW);                  /* mailbox            */
    l0[8] = LEAF(ROOT,    PV|PR|PW);                  /* page tables        */
    l0[9] = LEAF(L0,      PV|PR|PW);
    *(volatile unsigned *)0x4000u = 0x5A5A5A5Au;      /* user's data        */

    asm volatile ("csrw medeleg, %0" :: "r"((1u<<8)|(1u<<12)|(1u<<13)|(1u<<15)));
    asm volatile ("csrw mtvec, %0"   :: "r"((unsigned)&m_trap));
    asm volatile ("csrw stvec, %0"   :: "r"((unsigned)&s_trap));
    asm volatile ("csrw satp, %0"    :: "r"(0x80000000u | (ROOT >> 12)));
    asm volatile ("sfence.vma");

    asm volatile ("csrr %0, mstatus" : "=r"(ms));
    ms = (ms & ~(3u << 11)) | (1u << 11);             /* MPP = S            */
    asm volatile ("csrw mstatus, %0" :: "r"(ms));
    asm volatile ("csrw mepc, %0"    :: "r"((unsigned)&s_main));
    asm volatile ("mret");
    return 0;
}
