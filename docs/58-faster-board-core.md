# Step 58 — A faster board core: 11.11 → 50 MHz

Step 57's bitstream ran the core at 11.11 MHz, with nextpnr putting it at
18.24 MHz after routing. This step goes after the critical path, one path
at a time, until the core routes at 51.47 MHz with the best placement
seed. FCLK1 is now 50 MHz (IO PLL / 20), 4.5 times Step 57's clock, and
the shell comes up about 7.5 s after U-Boot starts instead of 26 s.

It happened in two rounds. The first (to 40.8 MHz) took the long chains out
of EX, flushes and branches, and the board ran at 33.33 MHz for a while.
The second precomputed the forwarding compares, registered the fetch
page's translation, and took the carries out of the address decodes. That
put the core's median at about 49 MHz and its best seeds above 50.

**The margin is thin: 2.9 %, on nextpnr's estimate.** Across 18 placement
seeds the same netlist routes at 43.8–51.5 MHz, and the build keeps seed
18, the best. The paths left are about 19–20 ns, nearly all routing, in
the D-port's load path. The 33.33 MHz build (22 % margin) stays in git
history as the fallback (below).

Every change is a parameter on `cpu_pipe_u` (default 0), except a few exact
rewrites that apply to every configuration. `fpga_top_linux`, the
`board-ddr` simulation variant, the `*_board` riscv-tests cores and `make
pipe-u-board` turn the parameters on. Every other configuration is
unchanged: `make boot` gives the same cycle counts as before this step.

## The result

| | Step 57 | Step 58, first round | Step 58 |
|---|---|---|---|
| core clock | 11.11 MHz (IO PLL / 90), UART divisor 6 | 33.33 MHz (/ 30), divisor 18 | **50 MHz** (/ 20), divisor 27 |
| core clock after routing | 18.24 MHz | 40.79 MHz (22 % margin) | **51.47 MHz** (2.9 % margin, seed 18) |
| FCLK0 (GP0's registers) after routing | 250.9 MHz | 216.7 MHz | 204.2 MHz (needs 100) |
| nextpnr LUT sites (of 35,200) | 12,974 (36 %) | 12,655 (35 %) | 12,496 (35 %) |
| flip-flop sites | 4,281 | 4,452 | 4,523 (12 %) |
| `CARRY4` / RAMB36 / DSP48 | 442 / 8 / 4 | 417 / 8 / 4 | 382 / 8 / 4 |
| routing | 8 iterations | 5 iterations | 5 iterations, 89 s |
| U-Boot start to the Linux shell | 26 s | about 10 s | about 7.5 s |

The bitstream is `riscv_linux.bit` in OpenZynq's
`projects/riscv_linux/prebuilt/`, 2,083,867 bytes, IDCODE `0x03722093`,
sha256 `b73b6498…d4b73399`. OpenZynq's `project.mk` gives nextpnr `--freq 50
--seed 18` (`OZ_SEED` in `tools/rvlinux`), so `make bit` reproduces it. Any
change to the netlist, the boot ROM's contents included, needs a new seed
sweep. The U-Boot + Linux image reads the clock from the device tree that
the ROM writes, so it does not depend on the bitstream.

As before, this has not been on a board, and the timing is nextpnr's
estimate from prjxray's data, not a sign-off.

## One path at a time

nextpnr reports one critical path per clock. Each row fixes the path the
row above it reported. Placement seeds move the figure by about ±5 %, so
the small dips are noise. The new worst path was a different one each
time.

| change | core clock after routing | the path it removed |
|---|---|---|
| Step 57 | 18.24 MHz | — |
| `AGU`, `MUL_2C` | 32.49 MHz | forwarding → the 32×32 multipliers → the ALU result → the load/store address → D-TLB → fault, 54.8 ns |
| `XLATE_2C` | 40.50 MHz | forwarding → address adder → D-TLB → region check / faults → trap → pipeline control |
| trap qualification restated | 39.87 MHz | `take_trap` (all of the faults) → `mret` / `sret` / CSR commit |
| walker: late kill, registered physical address | 37.42 MHz | a page-table walk's result → the D-TLB fill → the same cycle's address |
| walker: `REG_RESULT` | 37.92 MHz | PTE read data → the leaf checks → the TLB fill |
| `VALID_FLUSH`, IF/ID and ID/EX | 42.65 MHz | branch compare → mispredict → `flush` → the reset of every ID/EX field (a few hundred flip-flops) |
| `VALID_FLUSH`, EX/MEM | 40.46 MHz | the trap / hold logic → `ex_keep` → the reset of every EX/MEM field |
| `REG_REDIRECT` | 41.12 MHz | forwarding → `opB` → branch compare → mispredict → the next-PC mux |
| final build at `--freq 33.33` | 40.79 MHz | — (the board ran at 33.33 MHz here) |
| `FWD_PRE` | 49.40 | MEM/WB forwarding compare → ALU operand → CSR write, and the other forwarding compares |
| IF/ID data fields off the flush | 42.88 | a trap decided in EX → `flush` → every IF/ID field's enable |
| carry-free region checks | 45.80 | `pc` → I-TLB → region check (`a - base < size`: a subtract, then a compare) → `if_ok` |
| walker address as a concatenation; carry-free ROM decode | 46.00 | walker → PTE address adder → the SoC's ROM range compare → D-TLB fill |
| `REG_REDIRECT`: misaligned target off the compare | 45.46 | forwarding → branch compare → misaligned-target trap → `flush` → walker start |
| `IF_PAGE` | 50.23 (best of 3) | `pc` → I-TLB → address → region check / I-cache → refill start |
| `HPM_LATE` | 50.73 (best of 6) | D-cache hit → `freeze` → the stall counter's 64 enables |
| walker fault late kill; `ip_*` load off the invalidation | 50.57 (best of 12) | `freeze` → trap → `flush` → walker `kill` → fault → `ip_*` |
| 50 MHz ROM, `--seed 18` | **51.47** (best of 18) | — |

From `FWD_PRE` on, one build's figure means little: the seed moves it by
±7 %. The later rows are the best of several seeds on the same netlist.

The worst path in the shipped build runs from the walker's address
(`satp`) through the D-port's address mux and the D-cache to the D-TLB's
fill: 19.4 ns, of which 17.2 ns is routing. Its neighbours on other seeds
are the same family: the D-port address → the D-cache's LUT-RAM data or
tags → the load data or `freeze` → MEM/WB, a CSR, or a counter.

### `AGU`, `MUL_2C` (committed first, `49864bc`)

A load's or store's address comes from its own adder (rs1 + imm), not
from the ALU's result mux. The multiplier latches its operands, multiplies
them into a result register, and holds EX for 2 cycles. One signed 33×33
multiply covers MUL, MULH, MULHSU and MULHU, which takes 12 DSP48s down to
4. `make mul-2c` checks 4,579 multiplies against the ALU's own products.

### `XLATE_2C`: a registered D-TLB lookup

A load or store now spends two cycles in EX. In the first it looks up the
D-TLB, and the hit, physical address, permissions and region (PMA) are
registered (`xl_*`). In the second the faults, the region check and the
commit use those registers. `xl_have` is cleared by anything that could
make the registered lookup stale: the instruction leaving EX, a TLB fill,
or an `sfence.vma`.
The vector unit keeps its own lookup, so `XLATE_2C` needs `V_EXT = 0`,
which the board build has.

The walker gets two matching options:

- `LATE_KILL`: a killed fetch-side walk's fill is suppressed only by the
  registered `killed` flag, not by the same-cycle `kill`. The worst case
  is an I-TLB entry for a wrong-path page, which is still a correct
  translation.
- `REG_RESULT`: the walk's result (good/bad, access fault, PTE,
  superpage) is registered, and reported in an extra `S_DONE` state. That
  moves the PTE checks off the path from the D-port's read data.

### The trap qualification

`mret`, `sret`, CSR writes and `sfence.vma` were gated by `~take_trap`,
which waits on every fault, the memory faults included. None of these
instructions is a branch, a jump or a memory access, so of all the
exceptions only `exc_sys` can be true for them: an instruction fault, an
illegal instruction, `ecall`, `ebreak` or a vector fault. Gating them on
`exc_sys` (and `irq_sys`) gives the same logic, with no wait on the
memory faults. This part is unconditional: it is the same function in
every configuration. `make boot`'s cycle counts confirm nothing changed.

### `VALID_FLUSH`: flush the valid bits only

A flush used to reset every field of IF/ID and ID/EX, and a bubble every
field of EX/MEM. That put the mispredict and `ex_keep` on the reset pin of
hundreds of flip-flops. With `VALID_FLUSH` the bubble clears only the
control bits: `valid` in IF/ID and ID/EX, and in EX/MEM `reg_write`,
`mem_read`, `mem_write`, the atomics' bits and `valid`. The other fields
load as usual and hold a dead instruction's values. This is safe because
everything in EX, and everything after it, already acts only on a valid
instruction or a set control bit. Forwarding checks `reg_write`, the
D-port checks `mem_read`/`mem_write`, and retirement checks `valid`.

### `REG_REDIRECT`: the branch redirects a cycle later

A mispredicted branch or jump (with no predictor, that is every taken one)
used to redirect the PC in the same cycle it resolved in EX. With
`REG_REDIRECT` the redirect is registered: `rr_valid`/`rr_pc`. The next
cycle, with the branch in MEM, it flushes and moves the PC. The
wrong-path instruction that entered EX meanwhile is killed through one
gate, `idex_valid = idex_valid_q & ~rr_valid`, because everything EX does
is gated by `idex_valid`. That covers its traps, CSR writes, memory
access, the divider and multiplier, the D-TLB capture and its walks.
Traps, `mret`/`sret` and `fence.i` still redirect at once. A taken branch
now costs one more cycle.

### `FWD_PRE`: the forwarding compares a cycle early

Forwarding compared `exmem_rd` and `memwb_rd` with `idex_rs1`/`rs2` in EX,
in front of the operand muxes, and `idex_csr_addr`'s low bits are the same
flip-flops as `idex_rs2`, which is why that name kept starting paths. With
`FWD_PRE` the four compares are registered from the values those registers
take next cycle: ID/EX's next `rs` (held, loaded from IF/ID, or zeroed by
a flush) against EX/MEM's next `rd` (held when MEM freezes, else ID/EX's).
MEM/WB's next `rd` is EX/MEM's. EX ANDs the registered match with
`reg_write`. That is exact: EX/MEM's or MEM/WB's next `rd` is only
approximate in a bubble, whose `reg_write` is 0. A simulation-only check
compares the registered matches with the live compares every cycle, and a
mutant (last cycle's `rd`) fails all 58 tests.

### `IF_PAGE`: a registered translation for the fetch page

Every fetch ran `pc` → the I-TLB's CAM → the physical address → the region
check and the I-cache's tag compare → `if_ok` → the PC's enable. With
`IF_PAGE` the I-TLB's answer for the page the PC is in is kept in registers
(`ip_vpn`, `ip_ppn`, the page fault and walk-fault flags). A fetch in that
page uses `{ip_ppn, pc[11:0]}` and no CAM. Leaving the page costs a cycle
with no fetch while the lookup is registered. The copy is dropped by
anything that can change a lookup's answer: any CSR write (`satp`,
`mstatus`), a trap, `mret`/`sret`, `sfence.vma`, and the end of any walk
(a fill, or a fault that sets `wres_*`). The region check stays live, on
the registered address, so it needs no assumption about region alignment.
A simulation-only check compares the copy with the live lookup on every
cycle it is used, through the riscv-tests, the Sv32 programs and the Linux
boot. Cost: 153 cycles over the 21M-cycle `board-ddr` test, and 0.4 % on
the Linux boot.

### The misaligned-target exception off the branch compare

A taken branch or jump to an address that isn't 4-aligned traps, and that
exception sat on the compare's path to `flush`. Bit 1 of a target is a
2-bit add: `jalr`'s `rs1 + imm` (in the ALU) and `pc + imm` for the
others. A jump always goes, so its trap needs no compare. A branch traps
only if taken, but a branch can be misaligned only through its immediate,
which compiled code without C never has. So such a branch spends one more
cycle in EX (`bq_*`) and traps on the registered outcome. A directed test,
`tests/riscv-tests/isa/rv32mx/ma_tgt.S` (`jal`, `jalr` +1/+2/+3 with
carries, taken and not-taken branches, a forwarded and a just-loaded
`rs1`), runs with the board cores' riscv-tests. A simulation-only check
compares the result with the full formula, and two mutants are caught.

### Exact rewrites, every configuration

- `pma()` compared `a - base < size`: a subtract, then a compare, two
  chained carries on every fetch and access. `in_region` gives the same
  answer as a masked compare for a power-of-two region on its alignment
  (RAM, CLINT, PLIC, UART, test), and as two parallel compares on the bits
  above the shared alignment otherwise (the ROM at `0x1000`–`0x5000`).
  0 mismatches in 4.8M checks against the old formula, with every address
  within ±70K of each region's edges included. `soc_boot`'s ROM decode
  gets the same treatment.
- The walker's PTE address `{ppn, 12'b0} + 4 * vpn[i]` never carries
  (`4 * vpn[i] < 4096`), so it is the concatenation.

### Smaller ones

- With `VALID_FLUSH`, IF/ID's data fields no longer have the flush on their
  enables. Only `valid` does.
- `HPM_LATE`: `hpmcounter3`..`7` (load-use, flush and fetch bubbles, D-port
  stalls, mispredictions: implementation-defined events) count their event
  a cycle late, from a register. `mcycle` and `minstret` stay exact.
- The walker's `LATE_KILL` also covers its fault report. A fetch-side walk
  killed in its last cycle may record that its page has no translation,
  which is true either way, and `sfence.vma` clears it.
- `IF_PAGE`'s data registers load independently of the invalidation, and
  only `ip_valid` sees it.

### Placement seeds

From about 49 MHz on, nextpnr's placement moves the result more than the
RTL changes do. The seed is a plain input (`--seed N`). The same netlist
and seed give the same result, so the build keeps the best one found.
Over 18 seeds the 50 MHz netlist routed at 43.8–51.5 MHz (median 49.3).
Four passed 50 MHz: seeds 18 (51.47), 15 (50.98), 7 (50.76) and 4
(50.41). The SA placer (`--placer sa`) was much worse here (34 MHz).

## The clock: 50 MHz

- The PS program writes `FPGA1_CLK_CTRL` = `0x00500400` (DIVISOR0 4,
  DIVISOR1 5) after `ps7_init`, and prints what it reads back.
- The board ROM and device tree are built with `PLAT_CLOCK_HZ=50000000
  UART_DIVISOR=27`, the same values the PL-oscillator build always used.
  `fpga_top_linux`'s reset divisor is 27, and LED2's heartbeat is bit 25
  (0.67 s).
- OpenZynq's `project.mk` gives nextpnr `--freq 50 --seed 18`.
- The simulation follows: the PS7 model's FCLK1 is 20 ns, the board top's
  bench samples 432 clocks a bit, and `board-ddr` uses divisor 27.

**The fallback.** If a board misbehaves at random (a timing failure rarely
fails cleanly), go back to 33.33 MHz. OpenZynq's commit `422f1e3` has that
bitstream, ROM and PS program together, and riscv-from-scratch's `f1747ed`
has its sources. Only the clock settings below differ, plus this step's
second-round parameters, which can stay on.

## The clock in the first round: 33.33 MHz

With the core at 40–42 MHz, the FCLK1 steps that keep 115200 baud within
0.5 % are 1000 / 30 = 33.33 MHz (divisor 18) and then 50 MHz (divisor 27).
33.33 MHz leaves 22 % margin on this build, and about 18 % on the worst
seed seen (40.46 MHz).

- The PS program writes `FPGA1_CLK_CTRL` = `0x00500600` (DIVISOR0 6,
  DIVISOR1 5) after `ps7_init`, and prints what it reads back.
- The board ROM and device tree are built with `PLAT_CLOCK_HZ=33333333
  UART_DIVISOR=18`. `fpga_top_linux`'s reset divisor is 18. LED2's
  heartbeat is bit 24 (0.5 s).
- OpenZynq's `project.mk` gives nextpnr `--freq 33.33`.
- The simulation follows: the PS7 model's FCLK1 is 30 ns, the board top's
  bench samples 288 clocks a bit, and `board-ddr` uses divisor 18.
- The kernel keeps its 100 Hz tick: 333,333 cycles a tick now.

## What it costs

| | cycles |
|---|---|
| a load or store | one more in EX (`XLATE_2C`) |
| a taken branch or jump | one more (`REG_REDIRECT`) |
| a multiply | 3 in EX (`MUL_2C`) |
| a fetch from a new page, and the first fetch after a CSR write, trap or walk | one (`IF_PAGE`) |
| a branch with a misaligned immediate (never in compiled code) | one |
| `board-ddr` boot test, `REG_REDIRECT` alone | 4,781,423 → 4,802,160 cycles at divisor 6 (mostly waiting on the UART) |
| `board-ddr`, `IF_PAGE` | +153 cycles at divisor 18 |

The extra cycles cost far less than the clock gains. U-Boot + Linux on the
board configuration reaches the shell at cycle 374.8M: 7.5 s at 50 MHz.
Part of that is the serial line, which takes more cycles a character at
each step up (UART divisor 6, 18, now 27). It was 10.1 s
at 33.33 MHz and 26 s at Step 57.

## Checks

| check | result |
|---|---|
| `tools/rvtests --core pipe_u_board`, `pipe_u_board_vm` (Sv32 on), `pipe_c_board_vm` (behind caches, Sv32 on), `pipe_c_uni_board` | 59/59, 59/59, 59/59, 60/60: `rv32ui`, `rv32um`, `rv32ua` and `rv32mx` (`ma_tgt`) all pass, with no simulation-only check firing |
| `tools/rvtests --core pipe_u`, `pipe_u_vm`, `pipe_c_vm` (the default core) | 90/90 each, unchanged |
| `make pipe-u-board`: the Step 41 TLB demo, atomics, per-process `satp` with preemption, an S-mode kernel with demand paging and a fetch fault, and delegation, on the board core | ALL PASS |
| `make pipe-u`, `make pipe-u-sv`, `make tlb`, `make bench-counters` (default core) | ALL PASS |
| `make div-iter`, `make mul-2c` | ALL PASS, 4,579 operations each |
| `make boot` (the other configurations) | ALL PASS, cycle counts identical to before this step |
| `make boot-board` | ALL PASS, both builds; `board-ddr` 21.0M cycles at divisor 27 |
| `rvlinux oz-sim`: the board top on OpenZynq's `ps7_gp0`, FCLK1 at 50 MHz | PASS, 0 HP0 protocol errors, the core ran 0 cycles early |
| U-Boot + Linux on the board configuration (`rvlinux run --uboot --board`) at 50 MHz | LINUX: ALL PASS, 20 output checks, the shell at cycle 374.8M, no simulation-only check firing |
| `make ps-test` | ALL PASS |
| `make linux-fast` (the default 50 MHz configuration), and `rvlinux run --fast` with Step 57's RTL on the same kernel `Image` | ALL PASS; 208,615,806 cycles with either RTL, identical. (The count moves between kernel builds, about ±0.5 %, because `linux-fast` rebuilds busybox and the initramfs and their bytes differ; Step 57's 207.1M was another build.) |

The new rvtests cores `pipe_u_board_vm` and `pipe_c_board_vm` run the
suite in U-mode with Sv32 on, on the board's core. That is the path
`XLATE_2C` and the walker changes touch.

## What more margin would take

The paths left are 19–20 ns on the best seeds, about 2 ns of logic and
17–18 ns of routing, in the MEM stage. The D-port's address (MEM's, or the
walker's or the vector unit's through a mux) goes into the D-cache's LUT
RAM, and its tag compare and data come out to `freeze`, the load data and
MEM/WB. Some of these paths are false: while the walker has the port, MEM
doesn't use what the cache returns. But nextpnr can't tell, and the real
MEM load path is nearly as long anyway. Real margin would take:

- **A pipelined D-cache**: data and tags in block RAM, read from the
  physical address that `XLATE_2C` already registers in EX, so MEM starts
  with them. That is a new cache, with its own verification.
- **Vivado.** Its placer and router typically do much better on 7-series
  than nextpnr-xilinx 0.9.3.
- **A floorplan** to keep the core compact. nextpnr-xilinx's support for
  that is limited.
