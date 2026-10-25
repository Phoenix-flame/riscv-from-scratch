/* counters.h - Step 48: read the cycle / instructions-retired counters.
 *
 * cpu_pipe_u (ZICNTR=1) has 64-bit mcycle and minstret, readable at every
 * privilege as cycle / instret in two 32-bit halves, plus four event
 * counters. Reading a 64-bit counter on RV32 needs the classic hi-lo-hi
 * loop: if the low half wrapped between the two reads of the high half,
 * read again. */
#ifndef COUNTERS_H
#define COUNTERS_H
#include <stdint.h>

#define CSR_READ(name) ({ uint32_t v_; __asm__ volatile ("csrr %0, " #name : "=r"(v_)); v_; })

#define RD64(lo, hi) ({ uint32_t h_, l_, h2_;                                   \
    do { h_ = CSR_READ(hi); l_ = CSR_READ(lo); h2_ = CSR_READ(hi); } while (h_ != h2_); \
    ((uint64_t)h_ << 32) | l_; })

static inline uint64_t rd_cycle64(void)   { return RD64(cycle, cycleh); }
static inline uint64_t rd_instret64(void) { return RD64(instret, instreth); }

/* The fixed-event counters of cpu_pipe_u (rtl/cpu_pipe_u.v). 3..6 count
 * the cycles in which no instruction left EX, by cause -- together with
 * instret they add up to cycle:
 *   hpmcounter3 load-use bubbles     hpmcounter4 flush bubbles
 *   hpmcounter5 fetch-stall bubbles  hpmcounter6 memory-freeze cycles
 *   hpmcounter7 mispredictions (events) */
typedef struct { uint64_t cyc, ins, lu, fl, fs, mf, mp; } perf_t;

/* Stop every counter (mcountinhibit, M-mode only), read them all, restart:
 * one consistent snapshot. The csrw that stops them still counts itself,
 * the one that restarts them does not, so a start/stop pair brackets
 * exactly the code in between -- plus one constant csrw. */
static inline void perf_read(perf_t *p)
{
    __asm__ volatile ("csrw mcountinhibit, %0" :: "r"(~0u));
    p->ins = rd_instret64();
    p->lu  = RD64(hpmcounter3, hpmcounter3h);
    p->fl  = RD64(hpmcounter4, hpmcounter4h);
    p->fs  = RD64(hpmcounter5, hpmcounter5h);
    p->mf  = RD64(hpmcounter6, hpmcounter6h);
    p->mp  = RD64(hpmcounter7, hpmcounter7h);
    p->cyc = rd_cycle64();
    __asm__ volatile ("csrw mcountinhibit, zero");
}

static inline void perf_diff(perf_t *d, const perf_t *a, const perf_t *b)
{
    d->cyc = b->cyc - a->cyc; d->ins = b->ins - a->ins; d->lu = b->lu - a->lu;
    d->fl  = b->fl  - a->fl;  d->fs  = b->fs  - a->fs;  d->mf = b->mf - a->mf;
    d->mp  = b->mp  - a->mp;
}

/* print n / d with three decimals, rounded, using integers only */
#include <stdio.h>
static inline void print_ratio3(uint64_t n, uint64_t d)
{
    uint64_t m = (n * 1000 + d / 2) / d;
    printf("%lu.%03lu", (unsigned long)(m / 1000), (unsigned long)(m % 1000));
}

#endif

/* the timed region's cycle budget, and the RESULT line tools/bench parses */
static inline void perf_report(const char *bench, const perf_t *d, unsigned n)
{
    uint64_t other = d->cyc - d->ins - d->lu - d->fl - d->fs - d->mf;
    printf("  where the cycles went (per %s):\n", bench[0] == 'd' ? "run" : "iteration");
    printf("    instructions     "); print_ratio3(d->ins, n);     printf("\n");
    printf("    load-use         "); print_ratio3(d->lu, n);      printf("\n");
    printf("    flushes          "); print_ratio3(d->fl, n);
    printf("   (");                   print_ratio3(d->mp, n);      printf(" mispredictions)\n");
    printf("    fetch stalls     "); print_ratio3(d->fs, n);      printf("\n");
    printf("    memory freezes   "); print_ratio3(d->mf, n);      printf("\n");
    printf("    other            "); print_ratio3(other, n);      printf("\n");
    printf("RESULT %s cycles=%lu instret=%lu n=%u loaduse=%lu flush=%lu fetch=%lu freeze=%lu "
           "mispred=%lu\n", bench, (unsigned long)d->cyc, (unsigned long)d->ins, n,
           (unsigned long)d->lu, (unsigned long)d->fl, (unsigned long)d->fs,
           (unsigned long)d->mf, (unsigned long)d->mp);
}
