/* smode_demo.c - Supervisor mode + trap delegation (medeleg/mideleg).
 *
 * Boot is in machine mode. main() programs medeleg so that ecall-from-U
 * (cause 8) and illegal-instruction (cause 2) are delegated to S-mode, and
 * mideleg so the supervisor software interrupt (cause 1) is delegated to S
 * as well; it installs both trap vectors and drops to an S-mode kernel. The
 * S kernel performs one ecall (cause 9) -- which is NOT delegated and so
 * lands in the M-mode handler, the contrast -- then drops to a U-mode task.
 *
 * The U task triggers an illegal instruction once, then loops issuing ecalls
 * and printing a dot. Each U ecall is delivered straight to the S handler,
 * which on every pass pends a supervisor software interrupt; that interrupt
 * is then delivered (also to S) the instant the handler returns to U. After a
 * fixed number of ecalls the S kernel halts the machine.
 *
 * No .rodata / .data (this SoC loads only instruction ROM; RAM starts zero):
 * results live at fixed RAM addresses and characters are immediates. */

#define UART_TX (*(volatile unsigned *)0x10000000u)
#define UART_ST (*(volatile unsigned *)0x10000004u)

extern void m_trap(void);
extern void s_trap(void);
extern void enter_s(unsigned entry);
extern void enter_u(unsigned entry);
static void s_kernel(void);
static void u_task(void);

static void uputc(char c){ while(!(UART_ST & 1u)){} UART_TX = (unsigned char)c; }

/* ---- U-mode task: runs translated-free, but unprivileged ---- */
static void u_task(void)
{
    unsigned i;
    asm volatile (".word 0xffffffff");      /* illegal instruction -> S (cause 2) */
    for (i = 0; ; i++) {
        *(volatile unsigned *)0x414u = i + 1;   /* u_progress */
        uputc('.');
        asm volatile ("ecall");                 /* -> S (cause 8); S halts after N */
    }
}

/* ---- S-mode kernel: enables its interrupts, shows the S->M ecall, drops to U ---- */
static void s_kernel(void)
{
    asm volatile ("csrs sstatus, %0" :: "r"(1u << 1));   /* SIE = 1 */
    asm volatile ("ecall");                              /* cause 9 -> M (not delegated) */
    enter_u((unsigned)&u_task);                          /* never returns */
}

/* ---- M-mode boot ---- */
int main(void)
{
    asm volatile ("csrw medeleg, %0" :: "r"((1u << 8) | (1u << 2))); /* ecall-U, illegal -> S */
    asm volatile ("csrw mideleg, %0" :: "r"(1u << 1));               /* SSIP -> S */
    asm volatile ("csrw mtvec,   %0" :: "r"((unsigned)&m_trap));
    asm volatile ("csrw stvec,   %0" :: "r"((unsigned)&s_trap));
    asm volatile ("csrw mie,     %0" :: "r"(1u << 1));               /* SSIE: allow SSIP */
    enter_s((unsigned)&s_kernel);                                    /* never returns */
    return 0;
}
