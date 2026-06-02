/* illegal_demo.c - run an undecoded instruction and catch the trap.
 * Demonstrates that an instruction the hardware doesn't implement now
 * FAULTS (mcause=2) instead of silently becoming a NOP. */
#include "firmware.h"

__attribute__((interrupt("machine")))
void trap_handler(void)
{
    unsigned cause, epc;
    __asm__ volatile ("csrr %0, mcause" : "=r"(cause));
    __asm__ volatile ("csrr %0, mepc"   : "=r"(epc));
    kprintf("TRAP! mcause=%u (2 = illegal instruction)  mepc=0x%x\n", cause, epc);
    halt(0);                       /* stop here; do not return */
}

int main(void)
{
    __asm__ volatile ("csrw mtvec, %0" :: "r"((unsigned)&trap_handler));
    kprintf("about to execute an undecoded instruction...\n");
    __asm__ volatile (".word 0x0000000b");   /* custom-0 opcode: not implemented */
    kprintf("THIS LINE SHOULD NOT PRINT (the trap should have fired)\n");
    halt(1);
}
