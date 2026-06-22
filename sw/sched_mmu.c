/* sched_mmu.c - memory-isolated processes: the preemptive scheduler (Step 25)
 * fused with the Sv32 MMU (Steps 22/24). Two user-mode tasks are preempted by
 * the timer exactly as before, but now each task has its OWN page table, and
 * the context switch reloads satp on every switch. Both tasks use the same
 * virtual addresses -- a private data page at VA 0x1000 and a stack at VA
 * 0x2000 -- yet those map to different physical pages, so neither can see or
 * corrupt the other's memory. The hardware MMU enforces the isolation; the
 * kernel just hands each task its own address space.
 *
 * No .rodata / initialized .data: this SoC loads the image into instruction
 * ROM only, so RAM starts zeroed and everything (page tables, contexts) is
 * built at run time. Page tables and task pages live at fixed physical
 * addresses well above the kernel's own code/data/stack. */
#include "firmware.h"

#define MTIME    (*(volatile unsigned *)0x10010000)
#define MTIMECMP (*(volatile unsigned *)0x10010004)

extern void trap_entry(void);
extern void launch(unsigned entry, unsigned stack);

/* ---- physical layout of page tables and task-backing pages (4 KiB each) --- */
#define ROOT_A 0x8000u   /* task A root (level-1) page table   */
#define ROOT_B 0x9000u   /* task B root page table             */
#define L0_A   0xA000u   /* task A level-0 table (low 4 MiB)   */
#define L0_B   0xB000u   /* task B level-0 table               */
#define PRIV_A 0xC000u   /* task A private data page  (VA 0x1000) */
#define STK_A  0xD000u   /* task A stack page         (VA 0x2000) */
#define PRIV_B 0xE000u   /* task B private data page  (VA 0x1000) */
#define STK_B  0xF000u   /* task B stack page         (VA 0x2000) */

#define SATP_A (0x80000000u | (ROOT_A >> 12))   /* Sv32 on, root PPN */
#define SATP_B (0x80000000u | (ROOT_B >> 12))

/* Sv32 PTE permission bits */
#define PV 1u
#define PR 2u
#define PW 4u
#define PX 8u
#define PU 16u

/* common virtual addresses (identical in both tasks) */
#define PRIV_VA  0x1000u           /* private data page  */
#define STK_TOP  0x3000u           /* top of the VA 0x2000 stack page */
#define INTERVAL 1500u
#define TICKS_MAX 24u

/* shared with the assembly handler: ctx[0]=mepc, ctx[2]=sp(x2),
 * ctx[r]=x_r, and ctx[32]=this task's satp. */
unsigned          ctx0[33], ctx1[33];
volatile unsigned cur, ticks;

static void uputc(char c){ while(!(UART_ST & 1u)){} UART_TX = (unsigned char)c; }
static void work(int n){ volatile int i; for(i=0;i<n;i++){} }

#define PTW(a) ((volatile unsigned *)(unsigned)(a))

/* Build one task's two-level page table. RAM is already zero, so only the
 * live entries are written; every other VA stays invalid (V=0) and faults. */
static void build_pt(unsigned root, unsigned l0, unsigned priv, unsigned stk)
{
    /* root[0] -> level-0 table (a pointer PTE: V set, R=W=X clear) */
    PTW(root)[0]    = ((l0 >> 12) << 10) | PV;
    /* root[0x40] -> 4 MiB superpage mapping VA 0x10000000 -> PA 0x10000000
     * (the UART), so a user task can print. Shared by both tasks. */
    PTW(root)[0x40] = (0x40u << 20) | PV|PR|PW|PU;
    /* level-0[1] -> private data page  (VA 0x1000) */
    PTW(l0)[1]      = ((priv >> 12) << 10) | PV|PR|PW|PU;
    /* level-0[2] -> stack page         (VA 0x2000) */
    PTW(l0)[2]      = ((stk  >> 12) << 10) | PV|PR|PW|PU;
}

/* Each task scribbles a task-tagged value into its private VA every pass and
 * prints its character. Same code shape, same VA -- different physical page. */
void taskA(void){
    volatile unsigned *p = (volatile unsigned *)PRIV_VA;
    unsigned c = 0;
    for(;;){ c++; *p = 0xA0000000u | (c & 0xFFFFu); uputc('A'); work(40); }
}
void taskB(void){
    volatile unsigned *p = (volatile unsigned *)PRIV_VA;
    unsigned c = 0;
    for(;;){ c++; *p = 0xB0000000u | (c & 0xFFFFu); uputc('b'); work(40); }
}

int main(void){
    int i;

    build_pt(ROOT_A, L0_A, PRIV_A, STK_A);
    build_pt(ROOT_B, L0_B, PRIV_B, STK_B);

    for(i=0;i<33;i++){ ctx0[i]=0; ctx1[i]=0; }
    ctx0[0]=(unsigned)taskA; ctx0[2]=STK_TOP; ctx0[32]=SATP_A;   /* mepc, sp, satp */
    ctx1[0]=(unsigned)taskB; ctx1[2]=STK_TOP; ctx1[32]=SATP_B;
    cur=0; ticks=0;

    asm volatile("csrw mscratch, %0" :: "r"(&ctx0[0]));      /* current = task A   */
    asm volatile("csrw mtvec,    %0" :: "r"((unsigned)&trap_entry));
    asm volatile("csrw mie,      %0" :: "r"(1u<<7));          /* MTIE: timer        */
    MTIMECMP = MTIME + INTERVAL;
    asm volatile("csrw satp,     %0" :: "r"(SATP_A));         /* task A's space     */

    launch(ctx0[0], ctx0[2]);                                /* enter task A (user) */
    return 0;
}
