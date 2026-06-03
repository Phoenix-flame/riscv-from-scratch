/* sched.c - a tiny preemptive multitasking kernel.
 *
 * Two user-mode tasks run "simultaneously": a periodic timer interrupt traps
 * into the machine-mode handler (trap_entry, in sched_asm.S), which saves the
 * running task, picks the other one round-robin, and resumes it. The tasks
 * never cooperate or yield -- they're preempted. The interleaved A/B output is
 * the proof. Tasks share one address space (no MMU here); each has its own
 * stack. The kernel stops after a fixed number of ticks. */
#include "firmware.h"
#define MTIME  (*(volatile unsigned *)0x10010000)
#define MTIMECMP (*(volatile unsigned *)0x10010004)

extern void trap_entry(void);
extern void launch(unsigned entry, unsigned stack);

/* shared with the assembly handler */
unsigned          ctx0[32], ctx1[32];   /* per-task saved state */
volatile unsigned cur, ticks;

static void uputc(char c){ while(!(UART_ST & 1u)){} UART_TX = (unsigned char)c; }
static void work(int n){ volatile int i; for(i=0;i<n;i++){} }   /* burn some time */

void taskA(void){ for(;;){ uputc('A'); work(60); } }
void taskB(void){ for(;;){ uputc('b'); work(60); } }

#define STACK_A 0x0F00u
#define STACK_B 0x0B00u
#define INTERVAL 1200u

int main(void){
    int i;
    for(i=0;i<32;i++){ ctx0[i]=0; ctx1[i]=0; }
    ctx0[0]=(unsigned)taskA; ctx0[2]=STACK_A;   /* mepc, sp */
    ctx1[0]=(unsigned)taskB; ctx1[2]=STACK_B;
    cur=0; ticks=0;

    asm volatile("csrw mscratch, %0" :: "r"(&ctx0[0]));   /* current = task A */
    asm volatile("csrw mtvec,    %0" :: "r"((unsigned)&trap_entry));
    asm volatile("csrw mie,      %0" :: "r"(1u<<7));       /* MTIE: timer IRQ */
    MTIMECMP = MTIME + INTERVAL;                            /* first tick */

    launch(ctx0[0], ctx0[2]);                              /* run task A (user mode) */
    return 0;                                               /* never reached */
}
