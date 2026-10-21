/* tlb_demo.c - translated instruction fetch + I/D TLBs (Step 41).
 *
 * The kernel builds one Sv32 address space and drops to user mode. The user
 * program (tlb_asm.S, section .utext) sits in ROM at PHYSICAL 0x1000 but the
 * kernel maps it at VIRTUAL 0x00403000, execute-only -- so it can only run if
 * the core translates the PC. It then exercises the TLBs: a hot loop (hits),
 * a read of its own execute-only code (load page fault), a PTE change the
 * D-TLB does not see until sfence.vma (stale translation), and a jump into a
 * mapped-but-not-executable page (instruction page fault, which ends the run).
 *
 * No .rodata / .data: the image goes to instruction ROM only, RAM starts
 * zeroed, and the page tables are built at run time at fixed addresses. */

#define PT_ROOT  0x2000u   /* level-1 table                              */
#define PT_L0    0x3000u   /* level-0 table for VA 0x00400000-0x007FFFFF */
#define UCODE_PA 0x1000u   /* user code page in ROM (.utext)             */
#define DATA_PA  0x4000u   /* user data page                             */

#define VA_CODE  0x00403000u   /* L0[3] -> UCODE_PA  X   (execute-only)  */
                               /* L0[4] -> DATA_PA   R W (VA 0x00404000) */
                               /* L0[6] -> DATA_PA   R W (no X: 0x00406000) */

#define PV 1u
#define PR 2u
#define PW 4u
#define PX 8u
#define PU 16u
#define LEAF(pa, perm) ((((pa) >> 12) << 10) | (perm))

extern void tlb_trap(void);

int main(void){
    volatile unsigned *root = (volatile unsigned *)PT_ROOT;
    volatile unsigned *l0   = (volatile unsigned *)PT_L0;
    unsigned ms;

    root[1]    = LEAF(PT_L0, PV);                 /* pointer -> level-0 table */
    root[0x40] = (0x40u << 20) | PV|PR|PW|PU;     /* UART 4 MiB superpage     */
    l0[3]      = LEAF(UCODE_PA, PV|PX|PU);        /* user code, execute-only  */
    l0[4]      = LEAF(DATA_PA,  PV|PR|PW|PU);     /* user data                */
    l0[6]      = LEAF(DATA_PA,  PV|PR|PW|PU);     /* same page, NOT executable */

    asm volatile ("csrw mtvec, %0" :: "r"((unsigned)&tlb_trap));
    asm volatile ("csrw satp, %0"  :: "r"(0x80000000u | (PT_ROOT >> 12)));
    asm volatile ("sfence.vma");                  /* new satp: drop old entries */

    asm volatile ("csrr %0, mstatus" : "=r"(ms));
    ms &= ~(3u << 11);                            /* MPP = U */
    asm volatile ("csrw mstatus, %0" :: "r"(ms));
    asm volatile ("csrw mepc, %0"    :: "r"(VA_CODE));
    asm volatile ("mret");
    return 0;
}
