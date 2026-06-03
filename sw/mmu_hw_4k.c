/* 4KiB two-level mapping test: VA 0x00800000 reaches the UART through a
 * level-1 POINTER + level-0 leaf (exercises the descend / S_PTW0D path). */
#include "firmware.h"
extern void htrap_entry(void);
#define PT1 0x2000u
#define PT0 0x3000u
#define VUART 0x00800000u
static void vpc(char c){
    volatile unsigned char *tx=(volatile unsigned char*)VUART;
    volatile unsigned *st=(volatile unsigned*)(VUART+4);
    while(!(*st&1u)){} *tx=(unsigned char)c;
}
void user_main(void){ vpc('4'); vpc('K'); vpc(' '); vpc('o'); vpc('k'); vpc('\n');
    *(volatile unsigned*)0x20000000u=1; for(;;){} }
static void enter_user(void(*e)(void)){ unsigned ms;
    asm volatile("csrr %0, mstatus":"=r"(ms)); ms&=~(3u<<11);
    asm volatile("csrw mstatus, %0"::"r"(ms));
    asm volatile("csrw mepc, %0"::"r"(e)); asm volatile("mret"); }
int main(void){
    volatile unsigned *pt1=(volatile unsigned*)PT1;
    volatile unsigned *pt0=(volatile unsigned*)PT0;
    pt1[0]=(0u<<20)|1|2|4|8|16;              /* identity superpage (code/stack) */
    pt1[2]=((PT0>>12)<<10)|1;                /* VA 8MiB -> POINTER to pt0 (non-leaf) */
    pt0[0]=(0x10000u<<10)|1|2|4|16;          /* leaf: -> UART PA, V R W U */
    asm volatile("csrw mtvec, %0"::"r"((unsigned)&htrap_entry));
    asm volatile("csrw satp, %0"::"r"(0x80000000u|(PT1>>12)));
    enter_user(user_main); return 0;
}
