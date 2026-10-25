# Step 48 — Benchmarks: Dhrystone and CoreMark

Every step so far has asked whether the CPU works. This one asks how fast it
is. A single number on a clock frequency we have not closed timing at would
say little, so we report the two **clock-independent** figures that embedded
cores are compared by:

- **DMIPS/MHz**: Dhrystone 2.x runs per second, divided by 1757 (the score
  of the VAX 11/780, the original "1 MIPS" machine), per MHz of clock.
- **CoreMark/MHz**: EEMBC CoreMark iterations per second, per MHz.

Simulation is a good place to measure them, because every cycle is counted
exactly. There is no timer resolution, no OS and no noise, so a few hundred
Dhrystone runs give the same answer as a few million. To count, the core needs
counters. This step adds them to `cpu_pipe_u`: the standard cycle and
instructions-retired counters, plus event counters that say **where every
other cycle went**.

The headline result is the unified pipeline on ideal (single-cycle) memory with the
branch predictor, gcc 13.2 and picolibc:

| | `-O2` | `-O3 -funroll-all-loops` | `-O3`, + Zba/Zbb/Zbs |
|---|---:|---:|---:|
| **Dhrystone** (DMIPS/MHz) | **1.368** | 1.358 | 1.371 |
| **CoreMark** (CoreMark/MHz) | **2.875** | 3.212 | **3.309** |

```
make bench-counters    # directed checks of the counters (Icarus)
make bench             # the full matrix below (tools/bench)
make bench-quick       # the headline -O2 row only, short CoreMark run
```

## Counting: Zicntr and Zihpm in `cpu_pipe_u`

A new parameter, `ZICNTR` (on by default, and a menuconfig option), adds seven
64-bit counters. They are read through the CSR instructions in 32-bit halves:

| CSR (M, read/write) | user alias (read-only) | counts |
|---|---|---|
| `mcycle` 0xB00 / `mcycleh` 0xB80 | `cycle` 0xC00 / `cycleh` 0xC80 | clock cycles |
| `minstret` 0xB02 / 0xB82 | `instret` 0xC02 / 0xC82 | instructions retired |
| `mhpmcounter3` 0xB03 / 0xB83 | `hpmcounter3` | load-use bubbles |
| `mhpmcounter4` 0xB04 / 0xB84 | `hpmcounter4` | flush bubbles (mispredictions, traps) |
| `mhpmcounter5` 0xB05 / 0xB85 | `hpmcounter5` | fetch-stall bubbles (I-port not ready) |
| `mhpmcounter6` 0xB06 / 0xB86 | `hpmcounter6` | memory-freeze cycles (D-port not ready) |
| `mhpmcounter7` 0xB07 / 0xB87 | `hpmcounter7` | mispredictions (events) |
| `mcountinhibit` 0x320 | — | bit *n* stops counter *n* |

Writes to the user aliases already trapped as illegal: the core treats any CSR
whose address bits `[11:10]` are `11` as read-only, which is how Step 47
protects `vl` and `vtype`. The privilege check is also the existing one:
address bits `[9:8]` give the lowest mode that may access the CSR, so the
`0xC..` aliases are readable from U and the `0xB..` ones only from M. There is
no `mcounteren`, so U and S can always read the counters. The event selectors
`mhpmevent3..7` are not implemented and read 0: each counter's event is fixed
in hardware. That is allowed, because the spec makes them WARL.

Reading a 64-bit counter on RV32 needs the usual loop. Read the high half,
then the low half, then the high half again. If the two high halves differ,
the low half wrapped in between, so read again (`sw/bench/counters.h`).

### Where `minstret` counts — a bug the test found

The obvious place to count an instruction is when it leaves WB; the SoC
already has a `retire` output there. The directed test showed why that is
wrong:

```
instret, adjacent reads: 1 ok
instret over 30 nops: 29 FAIL
```

The `csrr` executes in EX, but the instructions just in front of it are still
in MEM and WB. When bubbles from an earlier branch are draining through those
stages, the read misses instructions that are older than itself and already
committed. The spec wants the count of instructions **before** the read.

The fix comes from the pipeline's own design. Every trap commits in EX (Steps
42 and 44), so once an instruction leaves EX nothing can stop it from
retiring. `minstret` therefore counts `ex_go & ~take_trap`, and a `csrr` of
`instret` sees exactly the instructions older than itself. One check,
`instret right after a flush`, covers the bubbles case.

### Where the other cycles go — an exact budget

The first version of the event counters counted events where they happened: a
cycle with a load-use stall, a mispredict (costing two cycles), a cycle in
which the I-port was not ready. With caches the budget no longer added up.
After a mispredict, the bubbles from a fetch stall that were already counted
were squashed again and counted a second time. Overlapping causes give
overlapping counts.

The fix is to count **once, at one place**. Each cycle, EX does exactly one of
these things:

| EX this cycle | counted in |
|---|---|
| an instruction leaves EX (and does not trap) | `minstret` |
| the whole pipe is frozen on the D-port | `hpmcounter6` |
| it holds a bubble | the bubble's cause: 3, 4 or 5 |
| anything else (reset fill, trap entry, vector/walker holds) | none ("other") |

To know a bubble's cause when it reaches EX, the bubble is **tagged when it is
made** (`ifid_why`, `idex_why`, two bits each). IF makes a FETCH bubble when
the I-port is not ready and a FLUSH bubble on a redirect. ID makes a LOAD-USE
bubble, or a FLUSH bubble. The tag then moves down the pipe alongside the
bubble. The identity

```
cycle = instret + hpm3 + hpm4 + hpm5 + hpm6 + other
```

then holds by construction. In every benchmark run below, *other* is 0 within
the timed region. `tools/bench` fails a run whose categories add up to more
than `cycle`.

### `mcountinhibit` — a consistent snapshot

Even with exact counters, the budget was a few cycles off in some runs. The
counters are read one after another, so `instret` is sampled about 20 cycles
before `cycle`. An I-cache miss inside that read sequence falls into one
counter's window and not into another's. The start and end snapshots run with
different cache and predictor state, so the error does not cancel.

`mcountinhibit` fixes this, as the privileged spec intends. `perf_read()` sets
every bit, reads all seven counters at leisure and clears the bits again. The
counters stop together and restart together, so the snapshot is consistent.

### The directed test

`sw/bench/cnt_test.c` runs on ideal memory, where every expected value is
exact (`make bench-counters`, output compared with `tb/cnt_expected.txt`):

```
instret, adjacent reads: 1 ok
instret over 30 nops: 31 ok
instret right after a flush: 3 ok
cycle over 30 nops: 31 ok
minstreth after write: 5 ok
mcycle right after write 0: 0 ok          (the write wins over that cycle's tick)
mcountinhibit reads: 253 ok               (0xfd: bit 1, time, is hardwired 0)
cycle while inhibited: 0 ok
instret while inhibited: 0 ok
load-use bubbles: 2 ok                    (lw;addi  lw;nop;addi  lw;addi)
mispredictions: 1 ok                      (a taken branch the BTB has never seen)
flush bubbles: 2 ok
cycles for read + taken branch: 4 ok
csrw cycle -> trap: 1 ok
  mcause: 2 ok
csrr cycle: no trap: 1 ok                 (csrrs with rs1 = x0 is a read)
CNT-TEST: PASS
```

## The benchmarks

Both run bare-metal on picolibc (Step 37: `sw/picolibc_crt0.S`,
`sw/picolibc_retarget.c`, `sw/picolibc.ld`, a 64 KiB image mirrored into
instruction and data memory). Their sources are fetched into `third_party/`
at pinned commits, the same way as riscv-tests (Step 40). The files in this
repository are only the *ports*, the part each benchmark leaves to the
target: `sw/bench/`.

### Dhrystone

The source is riscv-tests' `benchmarks/dhrystone`. It is Dhrystone 2.1 with
two fixes (it calls itself "2.2"), and it is the variant usually called
"legal": `#pragma GCC optimize ("no-inline")` stops GCC from inlining
`Proc_1`…`Proc_8` into the loop. Dhrystone's rules forbid that, and without
the pragma an aggressive compiler inflates the score substantially. The port
consists of:

- `sw/bench/dhrystone/util.h` replaces riscv-tests' `util.h`. The program
  brackets the timed loop with `setStats(1)` / `setStats(0)` and times it with
  `read_csr(mcycle)`. Both now read our counters.
- `-Dmain=dhry_main`. Our own `main` (`dhry_port.c`) calls it, then checks the
  final values against the "should be" values the benchmark prints, and
  reports the result:

  ```
  DMIPS/MHz = runs * 10^6 / (1757 * cycles)
  ```

- `Ptr_Glob` and `Next_Ptr_Glob` point at records that the benchmark
  allocates with `alloca` in its own frame. Once `dhry_main` returns, our
  `printf` calls overwrite them. `setStats(0)` therefore copies them out right
  after the timed loop, and the check reads the copies.

**Hosted, not freestanding.** The first run gave 0.983 DMIPS/MHz at 520
instructions per run. It was built with `-ffreestanding`, which implies
`-fno-builtin`, so each `strcpy(Str_2_Loc, "DHRYSTONE PROGRAM, 2'ND STRING")`
became a call to picolibc's byte loop. riscv-tests builds its benchmarks
hosted (only `-fno-builtin-printf`), and so do the published numbers. GCC
then expands a copy of a 31-byte constant into word stores. Hosted, the same
source runs 378 instructions per run and scores **1.368**. `strcmp` stays a
library call either way: its arguments are not constants.

### CoreMark

The source is eembc/coremark, with `core_portme.c` / `core_portme.h` adapted
from its `barebones/` port (Apache 2.0, as the originals). The settings are a
static data block, one context, `HAS_FLOAT 0` (rv32im has no FPU), and
`printf` from picolibc.

The time base needs some explanation. CoreMark measures time in "ticks" and
converts them with `EE_TICKS_PER_SEC`. Our tick is one clock cycle, and we
**declare the clock to be 1 MHz**. CoreMark's own `Iterations/Sec` is then
exactly CoreMark/MHz. Its run rule, at least 10 seconds of timed execution or
the result is invalid, becomes at least 10⁷ cycles. The default of 40
iterations is about 12–20 million cycles, depending on the configuration.
CoreMark then prints its standard

```
Correct operation validated. See README.md for run and reporting rules.
```

which `tools/bench` requires. That line means the list, matrix and state CRCs
match the known values for the performance-run seeds (0, 0, 0x66). The size
must be the standard 2000 bytes, and the run must last 10 "seconds".
`--quick` runs 2 iterations. Those runs are flagged as short, and only the
CRCs are checked.

## Running them: `tools/bench`

`tools/bench` fetches the sources and builds each benchmark for each compiler
configuration. It then builds `tb/bench_tb.v` once per hardware
configuration, runs everything and prints a table, which it also writes to
`build/bench/results.md`.

**Verilator, if it is installed.** A CoreMark run is millions of cycles.
Icarus runs this pipeline at about 7,000 cycles per second, so the full matrix
(16 runs, about 130 M cycles) would take hours. Verilator 5
(`apt install verilator`) compiles the same testbench, using `--binary
--timing` so that `#5` clocks and `$readmemh` work unchanged. It runs at about
a million cycles per second, and the whole matrix takes under 3 minutes. Both
simulators produce **the same cycle counts**: Dhrystone at -O2 is 208,086
cycles in each. `tools/bench --sim iverilog` forces Icarus. The one RTL change
this needed was fencing `soc_pipe_c`'s testbench-only `peek()` helper with
`` `ifndef VERILATOR ``, because Verilator cannot resolve its hierarchical
references.

```
$ tools/bench
[bench] simulator: verilator;  CoreMark iterations: 40
[bench] building verilator model: ideal (ideal 1-cycle memory, BTB + 2-bit predictor)
  dhrystone O2     ideal       1.368 DMIPS/MHz    CPI 1.101      416.2 cycles/run
  coremark  O2     ideal       2.875 CoreMark/MHz CPI 1.110   347830.6 cycles/iter
  ...
BENCH: PASS (16 runs, results verified)
```

## Results

All runs are on `cpu_pipe_u` (RV32IMA + Zb*, M/S/U, Sv32 off; the programs
run in M). Software is gcc 13.2.0 with picolibc 1.8.6. Per-unit columns are
per Dhrystone run or per CoreMark iteration, and the stall columns are
cycles. *Hardware* is the memory system: `soc_pipe_u` (ideal) or `soc_pipe_c`
(Step 43's direct-mapped I-cache and write-back D-cache, 32-byte lines, on
`mem_slow` with the given first-word latency).

| bench | build | hardware | score | CPI | cycles | instr | load-use | flush | fetch | freeze | mispred. |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Dhrystone | `-O2` | ideal, predictor | **1.368** | 1.101 | 416.2 | 378.1 | 6.0 | 32.1 | 0 | 0 | 16.1 |
| Dhrystone | `-O3` | ideal, predictor | 1.358 | 1.112 | 419.1 | 377.1 | 4.0 | 38.1 | 0 | 0 | 19.0 |
| Dhrystone | `-O3` Zb | ideal, predictor | 1.371 | 1.107 | 415.1 | 375.1 | 4.0 | 36.1 | 0 | 0 | 18.0 |
| Dhrystone | `-O2` | ideal, not-taken | 1.134 | 1.328 | 502.1 | 378.1 | 6.0 | 118.0 | 0 | 0 | 59.0 |
| Dhrystone | `-O2` | 4+4 KiB, lat 40 | 1.089 | 1.382 | 522.6 | 378.1 | 6.0 | 32.1 | 105.6 | 0.9 | 16.1 |
| Dhrystone | `-O2` | 2+2 KiB, lat 10 | 0.652 | 2.311 | 873.5 | 378.1 | 6.0 | 32.1 | 457.0 | 0.4 | 16.1 |
| Dhrystone | `-O2` | 2+2 KiB, lat 40 | 0.371 | 4.062 | 1535.5 | 378.1 | 6.0 | 32.1 | 1118.4 | 0.9 | 16.1 |
| Dhrystone | `-O2` | 1+1 KiB, lat 40 | 0.223 | 6.751 | 2552.3 | 378.1 | 6.0 | 32.1 | 1983.4 | 152.7 | 16.1 |
| CoreMark | `-O2` | ideal, predictor | **2.875** | 1.110 | 347,831 | 313,242 | 20,337 | 14,252 | 0 | 0 | 7,126 |
| CoreMark | `-O3` | ideal, predictor | 3.212 | 1.126 | 311,297 | 276,546 | 20,355 | 14,396 | 0 | 0 | 7,198 |
| CoreMark | `-O3` Zb | ideal, predictor | **3.309** | 1.134 | 302,231 | 266,482 | 20,746 | 15,004 | 0 | 0 | 7,502 |
| CoreMark | `-O2` | ideal, not-taken | 2.430 | 1.314 | 411,592 | 313,242 | 20,337 | 78,013 | 0 | 0 | 39,007 |
| CoreMark | `-O2` | 4+4 KiB, lat 40 | 2.744 | 1.163 | 364,439 | 313,242 | 20,337 | 14,252 | 13,811 | 2,797 | 7,126 |
| CoreMark | `-O2` | 2+2 KiB, lat 10 | 2.789 | 1.144 | 358,503 | 313,242 | 20,335 | 14,252 | 9,535 | 1,139 | 7,126 |
| CoreMark | `-O2` | 2+2 KiB, lat 40 | 2.674 | 1.194 | 373,905 | 313,242 | 20,335 | 14,252 | 23,272 | 2,805 | 7,126 |
| CoreMark | `-O2` | 1+1 KiB, lat 40 | 1.964 | 1.625 | 509,124 | 313,242 | 20,333 | 14,252 | 114,578 | 46,720 | 7,126 |

(`-O3` is `-O3 -funroll-all-loops`; "Zb" adds `_zba_zbb_zbs` to `-march`.)

### Reading the table

**On ideal memory the core is close to one instruction per clock.** CPI is
1.10–1.13. The rest is mispredictions and load-use bubbles, in that order.
For Dhrystone they cost 32 + 6 cycles per run, on top of 378 instructions.
The divider is combinational and the caches are absent, so nothing else
stalls.

**The branch predictor is worth 18–21 %.** Without it, Step 44's pipeline
predicts not-taken, and every taken branch and every jump costs two flush
cycles. Mispredictions go from 16 to 59 per Dhrystone run, and from 7,126 to
39,007 per CoreMark iteration.

**Which mispredictions remain.** `tb/bench_tb.v` classifies them over the
whole program, and the two benchmarks differ. Dhrystone at -O2 has 4,597 on
conditional branches, 2,738 on `jal` and 4,583 on `jalr`. A `jalr` is a
function **return**. The BTB remembers one target per return instruction, but
`Proc_7` is called from three places, so its return goes somewhere new most
of the time. A `jal` has a fixed target, so it can only miss when its BTB
entry has been evicted, which happens in a 64-entry direct-mapped table
whose index bits alias. CoreMark is the opposite: 15,327 of its 18,563 are on
data-dependent conditional branches in the list, matrix and state-machine
kernels. The next step for Dhrystone is a small **return-address stack**,
which would remove most of the `jalr` misses (about 9 per run, roughly 4 %).
For CoreMark it is a better **direction predictor** (global history,
gshare). Neither needs any architectural change.

**The compiler matters as much as the hardware.** For CoreMark, `-O3
-funroll-all-loops` removes 12 % of the instructions. The bit-manipulation
extensions remove another 4 % (Step 46). In the binary, those are mostly
`zext.h` and `sext.h` (212 and 122 of them), because CoreMark's matrix
elements and CRCs are 16-bit, plus `sh2add` for array indexing. Together they make 3.309 against 2.875.
Dhrystone hardly moves, because its no-inline rule and its tiny procedures
leave nothing to unroll. Its `-O3` build is even 0.7 % *slower*: code layout
changed which branches alias in the predictor (19.0 mispredictions per run
against 16.1). Treat differences of a percent or two in Dhrystone with that
in mind. Even adding the counter-reading code moved the `-O2` score from
1.348 to 1.368 during development.

**Caches: CoreMark fits, Dhrystone conflicts.** CoreMark's working set is
small. With 2 KiB caches at latency 10 it keeps 97 % of its ideal-memory
score, and 93 % at latency 40. Dhrystone collapses to 48 % and 27 %, almost
entirely in *fetch* stalls: 457 cycles per run at latency 10, about two dozen
line refills of ~19 cycles each. Its hot code is only
about 1.4 KiB, so this is not a capacity problem. It is **conflict**. Here is
the layout (`nm -n`, -O2):

```
0x009c  Proc_7, Proc_8, Func_1..3, Proc_6     \
0x0468  Proc_2, Proc_3, Proc_1, Proc_4, Proc_5  |  the timed loop calls all of these
0x07f8  dhry_main's loop body .. 0x09a8        |  every run
0x14e0  strcmp                                 /
```

A 2 KiB direct-mapped cache indexes with address bits [10:5]. The loop body
at 0x800–0x9a8 lands on the same lines as `Proc_7`…`Func_3` at 0x09c–0x1a8,
and `strcmp` at 0x14e0 lands on `Proc_1` at 0x4e0. Each run evicts and
refetches them. At 4 KiB the loop body and the procedures separate, and the
score recovers to 1.089. Only `strcmp`/`Proc_1` still collide (0x14e0 and
0x4e0 are 4 KiB apart). A 2-way set-associative I-cache, or a linker script
that places the hot code together, would fix this at 2 KiB. The CPI breakdown
says which one to try, and that is what the counters are for.

**At 1 KiB both benchmarks thrash,** and memory freezes (D-cache misses with
write-backs) appear as well: CoreMark's 2,000-byte data block plus its stack
no longer fit 1 KiB of D-cache.

### Context

Published scores for other cores come from different compilers, flags and
interpretations of the run rules. They are context, not a ranking. Arm, for
example, quotes about 0.9 DMIPS/MHz for the Cortex-M0, about 1.25 for the
Cortex-M3/M4, and 2.33 and 3.34 CoreMark/MHz for the M0 and M3. Those numbers
come from Arm's own compiler. A single-issue in-order pipeline with a
1-cycle multiplier and divider and a small BTB is in Cortex-M3/M4 territory
for CoreMark when the memory is fast.

Dhrystone's limits are well known. It is tiny, it is dominated by calls and
string copies, and the compiler can game it, as the 0.98 → 1.37 change from
builtins shows. CoreMark was designed to fix that: its work is computed from
seeds the compiler cannot see, and its result is verified by CRC. When the two
disagree, as they do here about caches, CoreMark is the one to trust for real
code.

## Cost

Yosys 0.33, `synth_xilinx -flatten -abc9 -arch xc7`, `cpu_pipe_u` alone in a
minimal configuration (RV32IM, M-mode only, no MMU, no Zb*, no V), with and
without `ZICNTR`:

| | LUTs | FFs | CARRY4 |
|---|---:|---:|---:|
| `ZICNTR=0` | 6,555 | 4,684 | 918 |
| `ZICNTR=1` | 7,156 | 5,143 | 1,030 |
| counters | **+601** | **+459** | **+112** |

The flip-flops are exactly the design: 7 × 64 counter bits, 7
`mcountinhibit` bits and the two 2-bit bubble tags. The CARRY4s are seven
64-bit incrementers (16 each). The LUTs go to the 32-bit read multiplexer over
14 counter halves and to each counter's write/increment select. The cost is about 9 % of this small core and about 5 % of
`oz_full`, which is why it is an option. Making the five event counters
32-bit would save roughly half of it. They would wrap after 4 G events, about
40 s at 100 MHz, and that is enough for most measurements.

## Menuconfig

`Core → ISA extensions → Zicntr + Zihpm` (pipeline only, default **y**).
rvgen passes `ZICNTR` through `oz_rv_soc` to `cpu_pipe_u`, and the self-test
gains a check that `instret` is exact, that `cycle` counts and that the `cycle`
alias is read-only. With the option off, it checks that `cycle` reads 0. The
preset defconfigs pick the new option up at its default. Their synthesis
tables in `docs/45` predate it, so with the default they are about 600 LUTs
low.

## Files

| file | |
|---|---|
| `rtl/cpu_pipe_u.v` | `ZICNTR`: counters, bubble tags, `mcountinhibit`, CSR routing |
| `rtl/soc_pipe_u.v`, `rtl/soc_pipe_c.v`, `rtl/oz/oz_rv_soc.v` | `ZICNTR` parameter; `soc_pipe_c`'s `peek()` fenced from Verilator |
| `sw/bench/counters.h` | 64-bit reads, `perf_read` (inhibit/snapshot), the cycle-budget report |
| `sw/bench/cnt_test.c`, `tb/cnt_expected.txt` | directed counter checks (`make bench-counters`) |
| `sw/bench/dhrystone/util.h`, `dhry_port.c` | the Dhrystone port |
| `sw/bench/coremark/core_portme.c`, `core_portme.h` | the CoreMark port |
| `tb/bench_tb.v` | runs one image on `soc_pipe_u` or (`-DCACHED`) `soc_pipe_c`; Icarus or Verilator |
| `tools/bench` | fetch, build, simulate, tabulate (`make bench`, `make bench-quick`) |
| `Kconfig`, `tools/rvgen/rvgen.py`, `sw/oz/selftest.c` | the option, its plumbing, its self-test |
