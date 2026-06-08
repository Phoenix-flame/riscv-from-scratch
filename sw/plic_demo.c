/* plic_demo.c - drive the PLIC: priorities, enable, threshold, claim/complete.
 *
 * Sources: 1 = UART, 2..4 = external lines irq_ext[1..3].
 * The ISR claims pending interrupts in priority order (highest first), records
 * the order, and completes each. main runs two phases the testbench drives:
 *   phase 1: all three external lines pulsed at once -> claimed in priority order.
 *   phase 2: threshold raised so low-priority sources are masked (left pending).
 *
 * Handshake/result words live at fixed RAM addresses the testbench reads. */
#define PLIC        0x10020000u
#define PRIO(i)     (*(volatile unsigned *)(PLIC + 4u*(i)))
#define PENDING     (*(volatile unsigned *)(PLIC + 0x1000))
#define ENABLE      (*(volatile unsigned *)(PLIC + 0x2000))
#define THRESH      (*(volatile unsigned *)(PLIC + 0x3000))
#define CLAIM       (*(volatile unsigned *)(PLIC + 0x3004))

#define M(a)        (*(volatile unsigned *)(a))
#define READY       M(0x800)
#define P1DONE      M(0x804)
#define P2READY     M(0x808)
#define DONE        M(0x80C)

volatile unsigned claimed[8];
volatile unsigned nclaim;

void __attribute__((interrupt("machine"))) trap_handler(void){
    unsigned id;
    while ((id = CLAIM) != 0u) {          /* drain in priority order */
        if (nclaim < 8u) claimed[nclaim++] = id;
        /* a real device would be cleared here; the external lines are pulses */
        CLAIM = id;                        /* complete */
    }
}

int main(void){
    nclaim = 0;
    PRIO(1) = 2; PRIO(2) = 3; PRIO(3) = 7; PRIO(4) = 5;   /* per-source priority */
    ENABLE  = (1u<<1)|(1u<<2)|(1u<<3)|(1u<<4);            /* enable sources 1..4 */
    THRESH  = 0;                                          /* let everything in   */

    __asm__ volatile("csrw mtvec, %0" :: "r"((unsigned)&trap_handler));
    __asm__ volatile("csrs mie,    %0" :: "r"(1u<<11));   /* MEIE */
    __asm__ volatile("csrs mstatus,%0" :: "r"(1u<<3));    /* MIE  */

    /* phase 1: priority ordering (expect claims 3,4,2 for prios 7,5,3) */
    READY = 1;
    while (nclaim < 3u) { }
    M(0x810) = claimed[0]; M(0x814) = claimed[1]; M(0x818) = claimed[2];
    P1DONE = 1;

    /* phase 2: threshold masks priorities <= 4 (src2 prio 3 stays pending) */
    nclaim = 0;
    THRESH = 4;
    P2READY = 1;
    while (nclaim < 2u) { }
    M(0x820) = claimed[0]; M(0x824) = claimed[1];
    M(0x828) = PENDING;            /* src2 should still be pending (masked) */
    DONE = 0x600D;
    for (;;) { }
    return 0;
}
