/* mmu_demo.c - Sv32 virtual memory with a NON-identity mapping.
 * Machine mode builds a page table mapping:
 *   - VA [0, 4MiB)            -> PA [0, 4MiB)        identity (code data/stack)
 *   - VA [0x00800000, +4MiB)  -> PA [0x10000000,..)  the UART, REMAPPED
 *   - everything else         -> unmapped
 * then drops to user mode. The user reaches the UART only through the
 * remapped virtual address 0x00800000 (its physical address 0x10000000 is
 * NOT mapped for the user), proving real address translation; then it
 * touches an unmapped address and takes a page fault. */
#include "firmware.h"

extern void mtrap_entry(void);

#define PT_BASE     0x2000u
#define VUART       0x00800000u           /* virtual UART (maps to 0x10000000) */
#define PTE_V 1u
#define PTE_R 2u
#define PTE_W 4u
#define PTE_X 8u
#define PTE_U 16u

volatile unsigned g_data;                 /* low RAM, identity-mapped */

static void uputc(char c){ *(volatile char *)VUART = c; }      /* via remapped VA */
static void uputs(const char *s){ while(*s) uputc(*s++); }

/* ---- USER mode: all data accesses are translated ---- */
void user_main(void){
    uputs("user: this text reaches the UART via VIRTUAL addr 0x00800000\n");
    uputs("user: (its physical addr 0x10000000 is not even mapped for me)\n");
    g_data = 0xC0FFEE;
    if (g_data == 0xC0FFEE)
        uputs("user: a mapped RAM page reads back correctly\n");
    uputs("user: now touching UNMAPPED 0x40000000 ...\n");
    *(volatile unsigned *)0x40000000u = 1;     /* -> store page fault */
    uputs("user: THIS SHOULD NOT PRINT\n");
    for(;;){}
}

static void enter_user(void (*entry)(void)){
    unsigned ms;
    asm volatile ("csrr %0, mstatus" : "=r"(ms));
    ms &= ~(3u << 11);
    asm volatile ("csrw mstatus, %0" :: "r"(ms));
    asm volatile ("csrw mepc, %0"   :: "r"(entry));
    asm volatile ("mret");
}

/* ---- MACHINE mode: untranslated; builds the page table ---- */
int main(void){
    volatile unsigned *pt = (volatile unsigned *)PT_BASE;
    pt[0] = (0u    << 20) | PTE_V|PTE_R|PTE_W|PTE_X|PTE_U;   /* identity low 4MiB */
    pt[2] = (0x40u << 20) | PTE_V|PTE_R|PTE_W|PTE_U;          /* VA 8MiB -> UART PA */

    asm volatile ("csrw mtvec, %0" :: "r"((unsigned)&mtrap_entry));
    asm volatile ("csrw satp, %0"  :: "r"(0x80000000u | (PT_BASE >> 12)));
    kprintf("kernel: page table built, Sv32 on, dropping to user mode\n");
    kprintf("kernel: mapped VA 0x00800000 -> PA 0x10000000 (UART)\n");
    enter_user(user_main);
    return 0;
}
