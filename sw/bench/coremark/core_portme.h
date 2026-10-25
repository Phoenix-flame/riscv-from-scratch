/* core_portme.h - Step 48: CoreMark port for the riscv-from-scratch SoCs.
 *
 * Adapted from coremark/barebones/core_portme.h (Copyright 2018 EEMBC,
 * Apache License 2.0). Bare metal, picolibc for printf, a static data
 * block, one context, timed with the cycle counter (cpu_pipe_u, ZICNTR).
 *
 * Time base: one tick = one clock cycle, and we declare the clock to be
 * 1 MHz (EE_TICKS_PER_SEC). CoreMark's "Iterations/Sec" is then exactly
 * CoreMark/MHz, and its 10-second validity rule becomes "at least ten
 * million cycles" -- see docs/48-benchmarks.md. */
#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#include <stddef.h>
#include <stdio.h>

#define HAS_FLOAT   0          /* rv32im: no FPU; we print the ratio in integers */
#define HAS_TIME_H  0
#define USE_CLOCK   0
#define HAS_STDIO   1
#define HAS_PRINTF  1          /* coremark.h then maps ee_printf to printf */

#ifndef COMPILER_VERSION
#define COMPILER_VERSION "GCC" __VERSION__
#endif
#ifndef COMPILER_FLAGS
#define COMPILER_FLAGS FLAGS_STR
#endif
#ifndef MEM_LOCATION
#define MEM_LOCATION "STATIC"
#endif

typedef signed short   ee_s16;
typedef unsigned short ee_u16;
typedef signed int     ee_s32;
typedef double         ee_f32;
typedef unsigned char  ee_u8;
typedef unsigned int   ee_u32;
typedef ee_u32         ee_ptr_int;
typedef size_t         ee_size_t;

#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x)-1) & ~3))

#define CORETIMETYPE ee_u32
typedef ee_u32 CORE_TICKS;

#define SEED_METHOD     SEED_VOLATILE
#define MEM_METHOD      MEM_STATIC
#define MULTITHREAD     1
#define USE_PTHREAD     0
#define USE_FORK        0
#define USE_SOCKET      0
#define MAIN_HAS_NOARGC 1
#define MAIN_HAS_NORETURN 0

typedef struct CORE_PORTABLE_S { ee_u8 portable_id; } core_portable;

extern ee_u32 default_num_contexts;

void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);

#if !defined(PROFILE_RUN) && !defined(PERFORMANCE_RUN) && !defined(VALIDATION_RUN)
#if (TOTAL_DATA_SIZE == 1200)
#define PROFILE_RUN 1
#elif (TOTAL_DATA_SIZE == 2000)
#define PERFORMANCE_RUN 1
#else
#define VALIDATION_RUN 1
#endif
#endif

#endif /* CORE_PORTME_H */
