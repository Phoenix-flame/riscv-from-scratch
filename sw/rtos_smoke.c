/* rtos_smoke.c - exercise the 64-bit CLINT + timer-interrupt path the same
 * way the FreeRTOS RISC-V port does: read 64-bit mtime, arm a 64-bit
 * mtimecmp, and take periodic machine timer interrupts. Not FreeRTOS yet,
 * just proof the prepared SoC supports what the port needs. */
#include "firmware.h"

#define MTIME_LO    (*(volatile unsigned *)0x10010000)
#define MTIME_HI    (*(volatile unsigned *)0x10010004)
#define MTIMECMP_LO (*(volatile unsigned *)0x10010008)
#define MTIMECMP_HI (*(volatile unsigned *)0x1001000C)
#define INTERVAL    3000ULL

static unsigned long long read_mtime(void){
    unsigned hi, lo;
    do { hi = MTIME_HI; lo = MTIME_LO; } while (hi != MTIME_HI);   /* rollover-safe */
    return ((unsigned long long)hi << 32) | lo;
}
static void arm_mtimecmp(unsigned long long v){
    MTIMECMP_HI = 0xFFFFFFFFu;                 /* avoid a spurious match mid-update */
    MTIMECMP_LO = (unsigned)v;
    MTIMECMP_HI = (unsigned)(v >> 32);
}

volatile unsigned ticks = 0;

__attribute__((interrupt("machine")))
void timer_isr(void){
    ticks++;
    kprintf("tick %d (mtime=%u)\n", ticks, (unsigned)read_mtime());
    arm_mtimecmp(read_mtime() + INTERVAL);     /* schedule the next tick */
    if (ticks >= 5){
        kprintf("CLINT + timer-interrupt path OK\n");
        halt(0);
    }
}

int main(void){
    kprintf("arming 64-bit CLINT...\n");
    arm_mtimecmp(read_mtime() + INTERVAL);
    asm volatile ("csrw mtvec, %0" :: "r"((unsigned)&timer_isr));
    asm volatile ("csrs mie,   %0" :: "r"(1u << 7));   /* MTIE  */
    asm volatile ("csrs mstatus,%0" :: "r"(1u << 3));  /* MIE   */
    for(;;){ }                                          /* wait for interrupts */
}
