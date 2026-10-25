/* util.h - Step 48: stands in for riscv-tests' benchmarks/common/util.h.
 *
 * third_party/riscv-tests/benchmarks/dhrystone/dhrystone_main.c includes
 * "util.h" and brackets the timed loop with setStats(1) / setStats(0);
 * dhrystone.h (the __riscv branch) times it with read_csr(mcycle). We map
 * both onto the user-level counters and keep the start/stop readings, so the
 * wrapper (dhry_port.c) can report cycles and instructions per run.
 *
 * The two records Ptr_Glob / Next_Ptr_Glob point to are alloca()ed in
 * dhrystone_main's frame and die when it returns, so setStats(0) -- right
 * after the timed loop -- also copies them out for the final-value check.
 * Included after dhrystone.h, so Rec_Type is known. */
#ifndef DHRY_UTIL_H
#define DHRY_UTIL_H
#include "../counters.h"

extern perf_t      dhry_p0, dhry_p1;
extern Rec_Pointer Ptr_Glob, Next_Ptr_Glob;
extern Rec_Type    dhry_glob, dhry_next;

#define read_csr(reg) ((long)CSR_READ(cycle))

static inline void setStats(int enable)
{
    if (enable) perf_read(&dhry_p0);
    else {
        perf_read(&dhry_p1);
        dhry_glob = *Ptr_Glob; dhry_next = *Next_Ptr_Glob;
    }
}
#endif
