/* =====================================================================
 * irq_demo.c  -  Timer interrupt demo.
 * A machine-timer interrupt fires periodically and an ISR increments a
 * counter, WHILE main() just spins. This shows true asynchronous
 * preemption: main never calls the ISR -- the hardware does.
 * ===================================================================== */
#include "firmware.h"

#define MTIME    (*(volatile unsigned *)0x10010000)
#define MTIMECMP (*(volatile unsigned *)0x10010004)
#define RAM0     (*(volatile unsigned *)0x00000000)

#define INTERVAL 200u           /* timer cycles between interrupts */

volatile unsigned ticks = 0;

/* The 'interrupt' attribute makes GCC emit the register save/restore
 * and the final `mret` for us. */
__attribute__((interrupt("machine")))
void mtimer_isr(void)
{
    ticks++;
    MTIMECMP = MTIME + INTERVAL;   /* rearm -> deasserts the IRQ line */
}

static inline void enable_timer_irq(void)
{
    /* point mtvec at the handler (direct mode: low 2 bits = 0) */
    __asm__ volatile ("csrw mtvec, %0" :: "r"((unsigned)&mtimer_isr));
    MTIMECMP = MTIME + INTERVAL;                 /* first deadline */
    __asm__ volatile ("li t0, 0x80; csrs mie, t0" ::: "t0"); /* MTIE  */
    __asm__ volatile ("csrsi mstatus, 0x8");                 /* MIE   */
}

int main(void)
{
    kprintf("main: enabling timer interrupts...\n");
    enable_timer_irq();

    /* Spin. We never call the ISR; the timer preempts us. */
    while (ticks < 5u) { /* do nothing */ }

    kprintf("main: observed %u timer interrupts\n", ticks);
    RAM0 = ticks;
    halt(0);
}
