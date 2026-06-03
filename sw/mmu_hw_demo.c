/* mmu_hw_demo.c - Sv32 MMU on the synthesizable core, page tables in BRAM.
 * Kernel maps VA 0x00800000 -> PA 0x10000000 (UART) and an identity low
 * page, drops to user; user prints via the remapped VA then faults on an
 * unmapped address. No .rodata: characters are immediates. */
#include "firmware.h"
extern void htrap_entry(void);

#define PT_BASE 0x2000u
#define VUART   0x00800000u           /* virtual UART (maps to 0x10000000) */

static void vpc(char c){             /* user: print via remapped virtual addr */
    volatile unsigned char *tx = (volatile unsigned char *)VUART;
    volatile unsigned *st = (volatile unsigned *)(VUART + 4);
    while (!(*st & 1u)) { }
    *tx = (unsigned char)c;
}

void user_main(void){
    vpc('u'); vpc('s'); vpc('e'); vpc('r'); vpc(':');
    vpc('V'); vpc('M'); vpc(' '); vpc('o'); vpc('k'); vpc('\n');
    *(volatile unsigned *)0x40000000u = 1;   /* unmapped -> page fault */
    for(;;){ }
}

static void enter_user(void (*e)(void)){
    unsigned ms;
    asm volatile ("csrr %0, mstatus" : "=r"(ms));
    ms &= ~(3u << 11);
    asm volatile ("csrw mstatus, %0" :: "r"(ms));
    asm volatile ("csrw mepc, %0"   :: "r"(e));
    asm volatile ("mret");
}

int main(void){
    volatile unsigned *pt = (volatile unsigned *)PT_BASE;
    pt[0] = (0u    << 20) | 1|2|4|8|16;     /* identity low 4MiB (V R W X U) */
    pt[2] = (0x40u << 20) | 1|2|4|16;       /* VA 8MiB -> UART PA (V R W U)  */
    asm volatile ("csrw mtvec, %0" :: "r"((unsigned)&htrap_entry));
    asm volatile ("csrw satp, %0"  :: "r"(0x80000000u | (PT_BASE >> 12)));
    enter_user(user_main);
    return 0;
}
