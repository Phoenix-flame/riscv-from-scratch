# Step 58 — A faster board core: 11.11 → 33.33 MHz

Step 57's bitstream ran the core at 11.11 MHz, with nextpnr putting it at
18.24 MHz after routing. This step goes after the critical path, one path
at a time, until the core routes at about 41 MHz. FCLK1 then moves to
33.33 MHz (IO PLL / 30), the fastest baud-exact step that leaves real
margin. That is three times Step 57's clock: the shell comes up about 10 s
after U-Boot starts instead of 26 s.

The aim was 50 MHz, and the core didn't get there. Each fix below took out
the worst path and exposed another at about 24 ns. By the end those paths
are spread across unrelated parts of the core, and 85–90 % of each one is
routing. The last section covers what 50 MHz would need.

Every change is a parameter on `cpu_pipe_u` (default 0). `fpga_top_linux`,
the `board-ddr` simulation variant and the `*_board` riscv-tests cores turn
them on. Every other configuration is unchanged: `make boot` gives the same
cycle counts as before this step.

## The result

| | Step 57 | Step 58 |
|---|---|---|
| core clock | 11.11 MHz (IO PLL / 90), UART divisor 6 | **33.33 MHz** (IO PLL / 30), UART divisor 18 |
| core clock after routing | 18.24 MHz | **40.79 MHz** (22 % margin) |
| FCLK0 (GP0's registers) after routing | 250.9 MHz | 216.7 MHz (needs 100) |
| nextpnr LUT sites (of 35,200) | 12,974 (36 %) | 12,655 (35 %) |
| flip-flop sites | 4,281 | 4,452 (12 %) |
| `CARRY4` / RAMB36 / DSP48 | 442 / 8 / 4 | 417 / 8 / 4 |
| routing | 8 iterations | 5 iterations, 101 s |
| U-Boot start to the Linux shell | 26 s | about 10 s |

The bitstream is `riscv_linux.bit` in OpenZynq's
`projects/riscv_linux/prebuilt/`, 2,083,867 bytes, IDCODE `0x03722093`,
sha256 `9efffba4…d54bbd3`. The U-Boot + Linux image is byte-for-byte the
one from Step 57: both read the clock from the device tree, which the boot
ROM writes, and the ROM is inside the bitstream.

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
| final build at `--freq 33.33` | **40.79 MHz** | — |

The path now reported runs from the walker's state, through the D-port
address mux and the SoC's address decode (`soc_boot.v`'s `in_rom`), to the
I-TLB's fill: 24.5 ns, of which 22.1 ns is routing.

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

## The clock: 33.33 MHz

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
| `board-ddr` boot test, `REG_REDIRECT` alone | 4,781,423 → 4,802,160 cycles at divisor 6 (mostly waiting on the UART) |

The extra cycles cost far less than the clock gains. U-Boot + Linux on the
board configuration reaches the shell at cycle 335.0M, 10.1 s at 33.33
MHz. That figure includes three times as many cycles per character on the
serial line as before. Step 57 took 26 s.

## Checks

| check | result |
|---|---|
| `tools/rvtests --core pipe_u_board`, `pipe_u_board_vm` (Sv32 on), `pipe_c_board_vm` (behind caches, Sv32 on), `pipe_c_uni_board` | 58/58, 58/58, 58/58, 59/59: `rv32ui`, `rv32um`, `rv32ua` all pass |
| `tools/rvtests --core pipe_u` (the default core) | 90/90, unchanged |
| `make div-iter`, `make mul-2c` | ALL PASS, 4,579 operations each |
| `make boot` (the other configurations) | ALL PASS, cycle counts identical to before this step |
| `make boot-board` | ALL PASS, both builds; `board-ddr` 14.0M cycles at divisor 18 |
| `rvlinux oz-sim`: the board top on OpenZynq's `ps7_gp0`, FCLK1 at 33.33 MHz | PASS: HP0 1,284 reads + 467 writes, 0 protocol errors, the core ran 0 cycles early |
| U-Boot + Linux on the board configuration (`rvlinux run --uboot --board`) | LINUX: ALL PASS, 20 output checks, the shell at cycle 335.0M |
| `make ps-test` | ALL PASS |
| `make linux-fast` (the default 50 MHz configuration), and `rvlinux run --fast` with Step 57's RTL on the same kernel `Image` | ALL PASS; 208,615,806 cycles with either RTL, identical. (The count moves between kernel builds, about ±0.5 %, because `linux-fast` rebuilds busybox and the initramfs and their bytes differ; Step 57's 207.1M was another build.) |

The new rvtests cores `pipe_u_board_vm` and `pipe_c_board_vm` run the
suite in U-mode with Sv32 on, on the board's core. That is the path
`XLATE_2C` and the walker changes touch.

## What 50 MHz would take

50 MHz is a 20 ns cycle. The paths left are about 24.5 ns, with about 2.5
ns of logic and 22 ns of routing in each, and there are many of them: the
reports show forwarding and branch resolution, the walker and the D-port,
and the CSR address. nextpnr's hops here are 1–3 ns each, and its placement
spreads the core across the die (35 % of the LUT sites, but routes that
cross half the chip). The options:

- **More pipelining** on each path as it surfaces: forwarding from a
  register (precomputed select), a registered D-port address decode, a
  CSR read a cycle early. Each costs a cycle somewhere and needs the same
  verification as this step. Each of the last four changes gained about
  0–5 %.
- **Vivado.** Its placer and router typically do much better on 7-series
  than nextpnr-xilinx 0.9.3. The same RTL could well close at 50 MHz
  there, but that is no longer the open flow.
- **A floorplan** (pblocks) to keep the core compact. nextpnr-xilinx's
  support for that is limited.
