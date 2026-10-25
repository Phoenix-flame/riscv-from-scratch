/* core_portme.c - Step 48: CoreMark port for the riscv-from-scratch SoCs.
 *
 * Adapted from coremark/barebones/core_portme.c (Copyright 2018 EEMBC,
 * Apache License 2.0). The timed region is bracketed by start_time() /
 * stop_time(); we read the cycle, instret and event counters there, and
 * portable_fini() prints the exact CoreMark/MHz and the cycle breakdown:
 *
 *   CoreMark/MHz = iterations * 10^6 / cycles */
#include "coremark.h"
#include "core_portme.h"
#include "../counters.h"

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

#define EE_TICKS_PER_SEC 1000000u     /* "a 1 MHz clock": ticks are cycles */

static perf_t p0, p1;

void start_time(void) { perf_read(&p0); }
void stop_time(void)  { perf_read(&p1); }

CORE_TICKS get_time(void) { return (CORE_TICKS)(p1.cyc - p0.cyc); }

secs_ret time_in_secs(CORE_TICKS ticks)
{
    return (secs_ret)ticks / (secs_ret)EE_TICKS_PER_SEC;
}

ee_u32 default_num_contexts = 1;

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc; (void)argv;
    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *))
        ee_printf("ERROR! Please define ee_ptr_int to a type that holds a pointer!\n");
    if (sizeof(ee_u32) != 4)
        ee_printf("ERROR! Please define ee_u32 to a 32b unsigned type!\n");
    p->portable_id = 1;
}

void portable_fini(core_portable *p)
{
    perf_t d; perf_diff(&d, &p0, &p1);
    p->portable_id = 0;
    printf("  cycles %lu  instret %lu  for %d iterations\n",
           (unsigned long)d.cyc, (unsigned long)d.ins, ITERATIONS);
    printf("  cycles/iteration "); print_ratio3(d.cyc, ITERATIONS);
    printf("  CPI ");              print_ratio3(d.cyc, d.ins);
    printf("  CoreMark/MHz ");     print_ratio3((uint64_t)ITERATIONS * 1000000u, d.cyc);
    printf("\n");
    perf_report("coremark", &d, ITERATIONS);
}
