/* cnt_test.c - Step 48: directed checks of cpu_pipe_u's counters.
 *
 * Runs on soc_pipe_u (ideal memory), so every number below is exact:
 *   - instret counts exactly the instructions between two reads, even
 *     right after a pipeline flush
 *   - with no stalls, cycle advances exactly one per instruction
 *   - hpmcounter3 counts one bubble per dependent load
 *   - hpmcounter7 counts a mispredicted branch, hpmcounter4 its 2 bubbles
 *   - mcycle / minstreth are writable in M; the write wins over the tick
 *   - mcountinhibit stops the counters
 *   - writing the read-only user alias `cycle` is an illegal instruction
 * Each check prints one line; tb/cnt_expected.txt is the expected output. */
#include "firmware.h"

#define CSR(name) ({ unsigned v_; __asm__ volatile ("csrr %0, " #name : "=r"(v_)); v_; })

static int fails;
static void check(const char *what, unsigned got, unsigned want)
{
    kprintf("%s: %u %s\n", what, got, got == want ? "ok" : "FAIL");
    if (got != want) fails++;
}

static volatile unsigned trap_cause, trap_count;
void trap_handler(void) __attribute__((interrupt("machine")));
void trap_handler(void)
{
    unsigned epc;
    trap_cause = CSR(mcause);
    trap_count++;
    __asm__ volatile ("csrr %0, mepc" : "=r"(epc));
    __asm__ volatile ("csrw mepc, %0" :: "r"(epc + 4));
}

#define NOP10 "nop; nop; nop; nop; nop; nop; nop; nop; nop; nop;"

int main(void)
{
    unsigned a, b, c, d;
    static volatile unsigned word = 41;

    /* back-to-back reads: the second instret read retires one later */
    __asm__ volatile ("csrr %0, instret; csrr %1, instret" : "=r"(a), "=r"(b));
    check("instret, adjacent reads", b - a, 1);
    __asm__ volatile ("csrr %0, instret;" NOP10 NOP10 NOP10 "csrr %1, instret" : "=r"(a), "=r"(b));
    check("instret over 30 nops", b - a, 31);
    /* ... even with bubbles still draining through MEM/WB behind the read */
    __asm__ volatile ("beqz zero, 1f; nop; 1: csrr %0, instret; nop; nop; csrr %1, instret"
                      : "=r"(a), "=r"(b));
    check("instret right after a flush", b - a, 3);
    __asm__ volatile ("csrr %0, cycle;" NOP10 NOP10 NOP10 "csrr %1, cycle" : "=r"(a), "=r"(b));
    check("cycle over 30 nops", b - a, 31);

    /* the 64-bit halves: mcycleh / minstreth are writable from M */
    __asm__ volatile ("csrw minstreth, %0" :: "r"(5));
    check("minstreth after write", CSR(instreth), 5);
    __asm__ volatile ("csrw mcycle, zero; csrr %0, mcycle" : "=r"(a));
    check("mcycle right after write 0", a, 0);   /* the write wins over that tick */
    __asm__ volatile ("csrw minstreth, zero");

    /* mcountinhibit: bit 1 (time) is hardwired 0; a stopped counter stays put */
    __asm__ volatile ("csrw mcountinhibit, %1; csrr %0, mcountinhibit" : "=r"(a) : "r"(~0u));
    check("mcountinhibit reads", a, 0xfd);
    __asm__ volatile ("csrr %0, cycle;" NOP10 "csrr %1, cycle" : "=r"(a), "=r"(b));
    check("cycle while inhibited", b - a, 0);
    __asm__ volatile ("csrr %0, instret;" NOP10 "csrr %1, instret" : "=r"(a), "=r"(b));
    check("instret while inhibited", b - a, 0);
    __asm__ volatile ("csrw mcountinhibit, zero");

    /* hpmcounter3: a load whose result the next instruction needs */
    __asm__ volatile (
        "csrr %0, hpmcounter3\n"
        "lw   t0, 0(%2); addi t0, t0, 1\n"      /* bubble */
        "lw   t0, 0(%2); nop; addi t0, t0, 1\n" /* no bubble */
        "lw   t0, 0(%2); addi t0, t0, 1\n"      /* bubble */
        "csrr %1, hpmcounter3\n"
        : "=r"(a), "=r"(b) : "r"(&word) : "t0");
    check("load-use bubbles", b - a, 2);

    /* hpmcounter7 / hpmcounter4: a forward branch, taken, never seen
     * before -- the predictor has no entry for it, so it guesses not-taken
     * and misses: one misprediction, two flush bubbles */
    __asm__ volatile (
        "csrr %0, hpmcounter7\n"
        "csrr %2, hpmcounter4\n"
        "beqz zero, 1f\n"
        "nop; nop\n"
        "1: csrr %3, hpmcounter4\n"
        "csrr %1, hpmcounter7\n"
        : "=r"(a), "=r"(b), "=r"(c), "=r"(d));
    check("mispredictions", b - a, 1);
    check("flush bubbles", d - c, 2);
    __asm__ volatile (
        "csrr %0, cycle\n"
        "beqz zero, 1f\n"
        "nop; nop\n"
        "1: csrr %1, cycle\n"
        : "=r"(c), "=r"(d));
    check("cycles for read + taken branch", d - c, 4);    /* 2 instructions + 2 flush */

    /* the user-level aliases are read-only: csrw cycle traps (cause 2) */
    __asm__ volatile ("csrw mtvec, %0" :: "r"((unsigned)&trap_handler));
    __asm__ volatile ("csrw cycle, zero");
    check("csrw cycle -> trap", trap_count, 1);
    check("  mcause", trap_cause, 2);
    /* ... but csrr (csrrs with rs1 = x0) is a read, not a write */
    a = CSR(cycle);
    check("csrr cycle: no trap", trap_count, 1);

    kprintf(fails ? "CNT-TEST: FAIL\n" : "CNT-TEST: PASS\n");
    halt(0);
    return 0;
}
