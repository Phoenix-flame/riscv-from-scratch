/* dhry_port.c - Step 48: run Dhrystone 2.x and report DMIPS/MHz.
 *
 * The benchmark itself is riscv-tests' copy (benchmarks/dhrystone, the
 * "legal" variant: #pragma GCC optimize("no-inline"), strcpy/strcmp from the
 * C library), compiled with -Dmain=dhry_main. Its own report goes through
 * debug_printf, which dhrystone.c defines empty; this file runs it, checks
 * the final values against the "should be" values, and turns the cycle
 * count of the timed loop into the standard figure of merit:
 *
 *   DMIPS     = Dhrystones per second / 1757   (the VAX 11/780 score)
 *   DMIPS/MHz = 10^6 / (1757 * cycles per Dhrystone)
 *
 * On simulation every cycle is counted exactly, so 500 runs is plenty. */
#undef main                 /* -Dmain=dhry_main is for dhrystone_main.c */
#include <string.h>
#include "dhrystone.h"
#include "util.h"

perf_t   dhry_p0, dhry_p1;             /* counters around the timed loop */
Rec_Type dhry_glob, dhry_next;         /* *Ptr_Glob / *Next_Ptr_Glob at the end */

int dhry_main(int argc, char **argv);

extern int         Int_Glob, Arr_1_Glob[50], Arr_2_Glob[50][50];
extern Boolean     Bool_Glob;
extern char        Ch_1_Glob, Ch_2_Glob;

static int fails;
static void want(const char *what, long got, long exp)
{
    if (got != exp) { printf("  FAIL: %s = %ld, should be %ld\n", what, got, exp); fails++; }
}

int main(void)
{
    printf("Dhrystone %s, %d runs\n", Version, NUMBER_OF_RUNS);
    dhry_main(0, 0);

    want("Int_Glob", Int_Glob, 5);
    want("Bool_Glob", Bool_Glob, 1);
    want("Ch_1_Glob", Ch_1_Glob, 'A');
    want("Ch_2_Glob", Ch_2_Glob, 'B');
    want("Arr_1_Glob[8]", Arr_1_Glob[8], 7);
    want("Arr_2_Glob[8][7]", Arr_2_Glob[8][7], NUMBER_OF_RUNS + 10);
    want("Ptr_Glob->Discr", dhry_glob.Discr, 0);
    want("Ptr_Glob->Enum_Comp", dhry_glob.variant.var_1.Enum_Comp, 2);
    want("Ptr_Glob->Int_Comp", dhry_glob.variant.var_1.Int_Comp, 17);
    want("Ptr_Glob->Str_Comp", strcmp(dhry_glob.variant.var_1.Str_Comp,
                                      "DHRYSTONE PROGRAM, SOME STRING"), 0);
    want("Next_Ptr_Glob->Ptr_Comp", (long)dhry_next.Ptr_Comp, (long)dhry_glob.Ptr_Comp);
    want("Next_Ptr_Glob->Discr", dhry_next.Discr, 0);
    want("Next_Ptr_Glob->Enum_Comp", dhry_next.variant.var_1.Enum_Comp, 1);
    want("Next_Ptr_Glob->Int_Comp", dhry_next.variant.var_1.Int_Comp, 18);
    want("Next_Ptr_Glob->Str_Comp", strcmp(dhry_next.variant.var_1.Str_Comp,
                                           "DHRYSTONE PROGRAM, SOME STRING"), 0);

    perf_t d; perf_diff(&d, &dhry_p0, &dhry_p1);
    printf("  cycles %lu  instret %lu  for %d runs\n",
           (unsigned long)d.cyc, (unsigned long)d.ins, NUMBER_OF_RUNS);
    printf("  cycles/run "); print_ratio3(d.cyc, NUMBER_OF_RUNS);
    printf("  CPI ");        print_ratio3(d.cyc, d.ins);
    printf("  DMIPS/MHz ");  print_ratio3((uint64_t)NUMBER_OF_RUNS * 1000000u, d.cyc * 1757u);
    printf("\n");
    perf_report("dhrystone", &d, NUMBER_OF_RUNS);
    printf(fails ? "DHRYSTONE: FAIL\n" : "DHRYSTONE: PASS (final values as specified)\n");
    return fails;
}
