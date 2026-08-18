# Step 40 — The official riscv-tests suite

Every step so far has been verified by a testbench written alongside the
hardware it checks. That is the right way to build — but it has a structural
weakness that grows quietly with the project: the tests were written by whoever
wrote the RTL, from the same reading of the specification. A misreading gets
baked into both halves at once, and the testbench cheerfully confirms it. The
two FPU bugs found in this step had been sitting behind a green FPU unit test
since Step 35 for exactly that reason.

[riscv-tests](https://github.com/riscv-software-src/riscv-tests) is the fix. It
is the reference suite the RISC-V project itself uses: for each instruction, a
program that checks the normal cases, the corner cases (`0x80000000`, `-1`,
shift amounts of 0 and 31), the aliasing cases (`rd == rs1`, `rs1 == rs2`,
`rd == x0`, `rs1 == x0`), and — the part a pipelined core cares about — the same
operation re-run with 0, 1 and 2 `nop`s between the producing and the consuming
instruction. Nobody on this project wrote a line of it. That is the whole point.

This step wires the suite up to five of the cores, runs 272 test programs, and
reports what comes back.

## What riscv-tests gives you, and what it deliberately does not

Clone the repository and you get `isa/rv32ui/add.S`, which is three lines:

```asm
#include "riscv_test.h"
#undef RVTEST_RV64U
#define RVTEST_RV64U RVTEST_RV32U
#include "../rv64ui/add.S"
```

and `isa/rv64ui/add.S`, which is a list of `TEST_RR_OP(...)` macros bracketed by
`RVTEST_CODE_BEGIN` / `RVTEST_CODE_END`. What you do **not** get is any
definition of those `RVTEST_*` macros. The `env/` directory in the checkout is
empty — upstream keeps the environment in a separate `riscv-test-env`
repository, and the reason is that there is no such thing as a portable one. The
environment is where the reset vector lives, where the trap vector lives, what
address the program is linked at, and how a finished test tells the outside
world whether it passed. Every one of those is a property of the target, not of
the ISA.

So porting riscv-tests to a new machine means writing exactly two files. They
live in `tests/riscv-tests/env/`, and they are the interesting part of this
step.

## The linker script: two memories, and a `tohost` that halts

Upstream's `p` environment links everything at `0x8000_0000` in one flat
address space, because it targets Spike. Our cores are Harvard: instructions
come from `imem` / `bram_rom`, data from `dmem` / `bram_ram`, and those are two
different arrays. `link.ld` therefore splits the program in two:

```
0x0000_0000 .. 0x0000_7FFF   ROM   .text.init + .text   (32 KB)
0x0000_8000 .. 0x0000_FFFF   RAM   .data + .bss         (32 KB)
0x2000_0000                  SYSCON halt register = tohost
```

`tohost` is riscv-tests' result word — a test finishes by storing to it. Rather
than putting it in RAM and polling, `link.ld` defines it as an absolute symbol
at `0x2000_0000`, which is the SYSCON address the SoCs have used since Step 11.
That makes the store that *reports* the result the same store that *stops* the
machine: the harness sees it on the bus, decodes it, and finishes. No polling
loop, no guessing a cycle count.

The encoding is upstream's:

| `tohost` | meaning |
|---|---|
| `1` | pass |
| `(n << 1) \| 1` | failed in sub-test *n* |
| `n \| 1337` | an unexpected trap reached `other_exception` |

## The environment header: three deliberate differences

`riscv_test.h` is upstream's `p` environment with three changes, each of which
is a statement about this hardware.

**The test body runs in machine mode, not user mode.** Upstream ends its reset
vector with `csrwi mstatus, 0` and an `mret`, which lands in U-mode, and it gets
away with that because `INIT_PMP` first installs a PMP entry granting user mode
full access. These cores have no PMP, and their user mode forbids *every* CSR
access — which the F tests need for `fcsr`. So the environment sets `MPP = 11`
before the `mret`. The instructions under test behave identically at either
level; what changes is only which privilege the harness happens to sit in.

**No `CHECK_XLEN`.** Upstream's version of that macro calls `RVTEST_PASS` on one
side of the branch. A harness that can report a pass without running the test is
a harness that can lie, and the build is pinned to `-march=rv32*` anyway.

**No `INIT_PMP`.** There is no PMP to initialise.

Everything else is upstream's, and that matters: the reset vector still probes
`mhartid`, still writes `satp` / `medeleg` / `mideleg` / `mie` behind a guard
that points `mtvec` at the following instruction, still enters the test body via
`mret`, and `RVTEST_PASS` / `RVTEST_FAIL` still funnel through `ecall` into the
trap vector. Reporting a result exercises `fence`, `ecall`, `mcause`, `mtvec`
and `mret` before a single instruction under test has been checked. A core that
gets its trap machinery wrong cannot even report a failure.

## The harness: one simulation, every program

`tb/rvtest_mc_tb.v` and `tb/rvtest_sc_tb.v` follow the pattern `tools/rvsim`
established: the program arrives at run time as a `+ROM=` / `+RAM=` plusarg, so
each core's simulation is compiled once and reused for every test. Both files
are thin — a core, a ROM, a RAM, and nothing else. There is no SYSCON device,
because `tb/rvtest_harness.vh` watches the data bus directly:

```verilog
always @(posedge clk) begin
    if (!rst && !rvt_done && rvt_wr && rvt_waddr[31:28] == 4'h2) begin
        ...decode rvt_wdata, print the verdict, $finish...
    end
end
```

Two harnesses rather than one because the cores fall into two bus families: the
BRAM-style bus (word address, byte-write mask, registered read) shared by
`cpu_mc`, `cpu_mc_c` and `cpu_mc_f`, and the byte-addressed `funct3` bus shared
by `cpu_core` and `cpu_pipe_trap`. Which core is instantiated is a `-D` at
compile time.

One system-level decision needs stating plainly. The data RAM image contains
`.data` at `0x8000` **and a copy of `.text` at 0** — the fetch path and the data
path see the same program image. The suite assumes a flat address space and
occasionally relies on it: `rv32uc-p-rvc` parks a test vector in the middle of
the code stream and reads it back with `c.lw`. Mirroring the image keeps fetch
genuinely read-only (the ROM is written once, at time zero) while letting the
data port read anything the linker placed in `.text`. The consequence is that
`fence_i` still fails — and fails for the one reason that is actually about this
hardware, rather than about where a linker put a constant.

## Running it

```bash
make riscv-tests                       # default core (cpu_mc)
make riscv-tests CORE=all              # every core, plus a summary matrix
make riscv-tests CORE=pipe ARGS="add sra"
make riscv-tests ARGS=--list

tools/rvtests --trace rv32ui-add       # one test, cycle by cycle
```

`tools/rvtests` clones the suite into `third_party/riscv-tests` on first use
(gitignored, pinned to a commit so a run is reproducible), reads each suite's
official test list out of its upstream `Makefrag` rather than hardcoding one,
builds every test, and runs them in parallel. A failure is reported with the
sub-test number the suite itself assigns, which is usually enough to find the
line in the `.S` file without opening a waveform.

## Results

| core | RTL | rv32ui | rv32um | other | total |
|---|---|---|---|---|---|
| `sc` | `cpu_core.v`, single-cycle RV32IMA | 41/41 | 8/8 | rv32ua 10/10 | **59/59** |
| `mc` | `cpu_mc.v`, multi-cycle RV32IM | 40/40 | 8/8 | — | **48/48** |
| `mc_c` | `cpu_mc_c.v`, multi-cycle RV32IMC | 40/40 | 8/8 | rv32uc 1/1 | **49/49** |
| `mc_f` | `cpu_mc_f.v`, multi-cycle RV32IMF | 40/40 | 8/8 | rv32uf 10/10 | **58/58** |
| `pipe` | `cpu_pipe_trap.v`, 5-stage pipeline | 41/41 | 8/8 | — | **49/49** |

Two details worth reading twice. The `mc_c` row builds the **entire** suite with
`-march=rv32imc`, so all 48 base-ISA tests run as compressed code — every one of
them exercises the RVC expander, the halfword-aligned PC and the straddling
fetch, not just the single `rv32uc-p-rvc` test. And the `pipe` row is the one
the bypass matrix was written for: `TEST_RR_DEST_BYPASS`, `TEST_RR_SRC12_BYPASS`
and `TEST_RR_SRC21_BYPASS` re-run each operation across every producer/consumer
distance, which is precisely the forwarding matrix a 5-stage pipeline has to get
right.

## What it found

The suite did not agree with the hardware everywhere. Two of the disagreements
were real bugs in `rtl/fpu_f.v`.

**`fmin.s(-0.0, +0.0)` returned `+0.0`.** The min/max branch of the FPU used the
same ordering expression as the compare branch, including this line:

```verilog
if (a[31]!=b[31]) less = a[31] && !(a_zero&&b_zero);
```

That `!(a_zero&&b_zero)` guard is *correct* for `flt.s` and `fle.s`, where
`-0.0` and `+0.0` compare equal. It is *wrong* for `fmin.s` and `fmax.s`, which
the spec explicitly requires to order the signed zeros: `fmin(-0.0, +0.0)` is
`-0.0`. The guard is now gone from the min/max branch and kept in the compare
branch, where it belongs. Caught by `rv32uf-p-fmin` cases 30–33.

**`fcvt.wu.s` had its invalid flag exactly backwards.** The old code raised NV
(invalid) when `|x| < 1` and negative, and raised *nothing* when a negative
value with `|x| >= 1` was converted to unsigned. The truth is the other way
round: `-0.9` truncates to `0`, which unsigned can represent, so that is merely
inexact; `-3.0` truncates to `-3`, which it cannot, so that is invalid. The same
routine also bailed out early at `sh >= 31`, saturating `fcvt.wu.s(3e9)` to
`0xFFFFFFFF` even though `3e9` fits comfortably in a 32-bit unsigned — the
55-bit intermediate is exact up to a shift of 31, so the cut belongs at 32.
Caught by `rv32uf-p-fcvt_w` cases 12, 13 and 19.

Both had survived the hand-written FPU unit test because that test compares
results against host `float32` and never checks `fflags` at all — and because
`gen_fpu_vectors.py`, written by the same hand as the RTL, never thought to
generate a negative-to-unsigned conversion or a signed zero. That is the failure
mode an external suite exists to catch.

## Known gaps

Three tests are reported separately rather than counted, because they fail for
reasons that are properties of the design rather than defects in it. They are
still *run* — a known gap should be visible as a result, not hidden behind a
skip — so if one ever starts passing, that shows up too.

**`rv32ui-p-fence_i` (all cores).** Self-modifying code. The instruction ROM is
written once, at time zero. No store can become an instruction, so `fence.i`
has nothing to make visible. This is a real architectural limit: it is what
stands between this machine and loading a program at run time, and it is the
same limit a bootloader would have to solve.

**`rv32ui-p-ma_data` (`mc`, `mc_c`, `mc_f`).** Misaligned accesses. These cores
select a sub-word inside a single RAM word from the address's low bits, so an
access that is not aligned to its own width reads or writes the wrong bytes —
and does so **silently**, with no trap. The spec permits an implementation to
either handle misaligned accesses or trap on them; quietly returning the wrong
answer is not one of the two options, so this one is a genuine (if
well-understood) hole rather than a design choice. Interestingly the
byte-addressed cores pass it outright: `dmem.v` indexes a byte array as
`{mem[a+3], mem[a+2], mem[a+1], mem[a]}`, which gets every alignment right
without anyone having planned for it.

**`rv32uf-p-fmadd` (`mc_f`).** `fmadd` / `fmsub` / `fnmadd` / `fnmsub` are not
implemented — Step 35 says so in the RTL header. A fused multiply-add has to
round the product and the sum *once*, together, which needs a wider intermediate
than the FPU carries. They decode as illegal instructions, which is at least the
honest failure: the core says "I don't know this" rather than computing
something plausible and wrong.

## A side effect: a fair cycle comparison

Because every core now runs the same 48 programs, their cycle counts are
directly comparable for the first time:

| test | `sc` | `mc` | `mc_c` | `pipe` |
|---|---|---|---|---|
| `add` | 495 | 989 | 1067 | 537 |
| `lw` | 313 | 649 | 739 | 341 |
| `beq` | 321 | 641 | 679 | 385 |
| `jalr` | 145 | 289 | 317 | 181 |
| `mul` | 489 | 977 | 1083 | 531 |
| `div` | 125 | 251 | 277 | 139 |
| **rv32ui + rv32um total** | **16954** | **34356** | **38318** | **18818** |

The single-cycle core is the floor: one instruction, one cycle, no fetch
penalty — and an impossible clock frequency, which is the trade the rest of the
table is about. The pipeline lands 11% above that floor, and the gap is exactly
the predict-not-taken flushes and load-use stalls Step 17 built in; note that
`beq` (20% over) is much worse than `add` (9%), which is the branch penalty
showing up where you would expect it. The multi-cycle core costs 2.03× because
every instruction pays a separate FETCH state for its registered ROM read. And
`mc_c` costs 12% more cycles than `mc` for identical work — the straddling-fetch
penalty from Step 34, paid back there in ~29% smaller code.

## What is not covered

The **`rv32mi` and `rv32si`** suites — machine-mode and supervisor-mode CSR
behaviour — are out of scope here, and concretely so: 11 of the 16 `rv32mi`
tests will not even assemble against this environment, because they use the
`CAUSE_*`, `PRV_*` and `MSTATUS_*` constants from upstream's full `encoding.h`,
which is part of the environment repository and would have to be written too.
Of the five that do build, `mcsr` and `pmpaddr` fail immediately, and the three
that pass do so against CSRs that read as a constant zero — `csr.v` implements
seven registers and silently returns zero for everything else, so
`rv32mi-p-zicntr` is passing over counters that do not exist. Making that suite
mean anything requires building out the machine CSR set first, not writing more
harness.

Also untested: the `-v` (virtual memory) variants of every suite, which need
fetch-side address translation the MMU does not do yet; `rv32ud` (double
precision) and the `rv32uzb*` bit-manipulation suites, which are extensions the
cores do not implement; and `cpu_mc_s`, `cpu_mc_mmu`, `cpu_mc_stall` and
`cpu_pipe_bp`, which are not yet wired into `tools/rvtests` — adding a core is a
dictionary entry plus, at most, an `ifdef` in one of the two harnesses.

## Takeaway

Writing your own tests proves your hardware matches your understanding. Running
somebody else's proves your understanding matches the specification. Those are
different claims, and only the second one is what "RV32I" means. The integer
cores came through clean; the FPU did not, and both of its bugs were in the
places where a specification is easy to half-read — the sign of zero, and which
side of a range check raises which flag.

The other half of the value is the reporting. A suite that hides its known gaps
behind a skip list slowly stops telling you anything. Running the three
impossible tests every time — and printing why each one is impossible — keeps
the difference between "we chose not to build this" and "this is broken" visible
in the output rather than buried in a commit message.
