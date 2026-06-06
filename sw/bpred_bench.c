/* bpred_bench.c - a branchy workload to exercise the predictor.
 *
 * Branch mix:
 *   - two nested loop back-edges (very predictable: taken N-1 of N times),
 *   - a data-dependent branch with a runs-of-4 pattern (NNNN TTTT ...),
 *     which a 2-bit counter handles well except at run boundaries,
 *   - a function call each odd run: jal (predictable target) + ret/jalr
 *     (single call site, so the return target is also predictable here).
 *
 * It writes a checksum to 0x100 and the sentinel 0x600D to 0x104 when done,
 * then spins. The testbench snapshots the cycle/branch counters the moment
 * the sentinel appears, so the final spin loop is not counted. */
#define RES  (*(volatile int *)0x100)
#define DONE (*(volatile int *)0x104)

static int __attribute__((noinline)) work(int x){ return (x ^ (x << 1)) + 7; }   /* callee: forces jal + ret */

int main(void){
    int acc = 0, i, j;
    for (i = 0; i < 30; i++){
        for (j = 0; j < 60; j++){
            if ((j >> 2) & 1) acc += work(i + j);   /* runs-of-4 taken pattern */
            else              acc -= (i ^ j);
        }
    }
    RES  = acc;
    DONE = 0x600D;
    for (;;) { }
    return 0;
}
