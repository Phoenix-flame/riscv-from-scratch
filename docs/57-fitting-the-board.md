# Step 57 — Fitting the board: a divider, a slower clock, and a bitstream

Steps 54–56 got the core to the Mitra-7010 in simulation. This step turns
`fpga_top_linux` into a bitstream with OpenZynq's open flow (Yosys 0.68,
nextpnr-xilinx 0.9.3, prjxray). The first attempt did not get there: the
design was too big to place, and then too slow for its 50 MHz clock. The
second one did, with three changes to the board build only:

1. **an iterative divider** (`DIV_ITER`) instead of the ALU's array
   dividers;
2. **a slower core clock**: the PS's FCLK1 at 11.11 MHz instead of the
   50 MHz oscillator;
3. **less logic**: no Zba/Zbb/Zbc/Zbs and no branch predictor, which
   nothing in the boot chain uses.

Every other configuration is unchanged; each change is a parameter.

> **Superseded clock:** Step 58 (`docs/58-faster-board-core.md`) shortens
> the board core's critical path to about 41 MHz and moves FCLK1 to
> 33.33 MHz (UART divisor 18). The figures below are Step 57's.

## The result

`riscv_linux.bit`, 2,083,867 bytes, IDCODE `0x03722093` (the xc7z010),
in OpenZynq's `projects/riscv_linux/prebuilt/` with its checksum.

| | first attempt | the bitstream |
|---|---|---|
| core | array dividers, Zb*, branch predictor | `DIV_ITER`, no Zb*, no predictor |
| core clock | 50 MHz, the PL oscillator | 11.11 MHz, the PS's FCLK1 |
| nextpnr LUT sites (of 35,200) | 24,978 (71 %) | 12,974 (36 %) |
| flip-flop sites | 7,996 | 4,281 (12 %) |
| `CARRY4` | 1,277 | 442 |
| placement | fails ("no legal placement") | completes; the post-place repair relocates 4,048 cells, all of them |
| routing | — | converges: no overuse after 8 iterations, 90 s |
| core clock after routing | — | **18.24 MHz** (needs 11.11: 64 % margin) |
| FCLK0 (GP0's registers) after routing | — | 250.9 MHz (needs 100) |
| build time | — | 5 minutes, synthesis included |

The routed netlist has the core's 5,280 clocked cells on `clk`, which
`u_ps7.bufg_fclk1` drives from the PS7's `FCLKCLK1`. HP0's clock pin is on
the same net; GP0's is on `aclk` (FCLK0, its own BUFG). The only warnings
are nextpnr's notes about the DSPs' unused cascade outputs.

It has not been on a board yet. Timing is nextpnr's estimate from
prjxray's data, not a sign-off.

## The area: the ALU's dividers

The first run failed at placement ("Unable to find legal placement for
cell … check constraints and utilisation"). Yosys reported about 15,100
cells, about 85 % of the part's 17,600 LUTs once the distributed RAM is
included. nextpnr then packed 23,923 LUT cells, not 15,000: it adds a
route-through `LUT1` where a flip-flop or a carry output has no LUT in
front of it, 8,949 of them, which is roughly seven per `CARRY4`. That is
24,978 of its 35,200 LUT sites (71 %, where a 5-input LUT can share a
6-LUT only if the pair's inputs fit), too many to place.

A per-module breakdown put the ALU first by a wide margin. `alu.v`
writes `DIV`, `DIVU`, `REM` and `REMU` as Verilog `/` and `%`, which
synthesises to combinational array dividers (its header says so: "a real
core uses a multi-cycle divider"). They were most of the LUTs, and most of
the carry chains that nextpnr inflates.

### The fix: `DIV_ITER`

`div_iter` (at the bottom of `alu.v`) is a restoring divider that yields
one quotient bit a cycle on the unsigned magnitudes, with the signs and
RV32M's special cases (x/0 = −1, x%0 = x, −2³¹/−1) applied around it. A
divide takes 33 cycles from entering EX to leaving it. `cpu_pipe_u`'s
`DIV_ITER` parameter selects it (default 0, so every other configuration is
unchanged and cycle-identical). A divide in EX holds the instruction
through the existing `ex_hold`, the way a vector op or a page-table walk
does, and a flush or trap while it runs aborts it. `soc_boot` passes the
parameter on, and `fpga_top_linux` and the `board-ddr` test variant turn it
on.

| | array dividers | `DIV_ITER` |
|---|---|---|
| nextpnr LUT sites (of 35,200) | 24,978 (71 %) | 16,991 (48 %) |
| `CARRY4` | 1,277 | 480 |
| route-through `LUT1` | 8,949 | 3,386 |
| placement | fails | completes |

Checks:

- `make div-iter` (`tb/div_iter_tb.v`) runs 4,579 divisions through the
  handshake against the ALU's own array divider: corners (0, ±1, 2³¹,
  2³¹−1, divide by zero, the signed overflow) in all four operations, 4,000
  random pairs of random width, a mid-run abort, an unfrozen hold, and a
  frozen first cycle. Each takes exactly 33 cycles. A mutant with the wrong
  remainder sign fails it. (The overflow special case is redundant:
  the algorithm gets it right on its own. It stays, for clarity.)
- `tools/rvtests --core pipe_u_div` and `pipe_c_uni_div` run the whole
  official suite on the pipeline with `DIV_ITER=1`: `rv32um` 8/8 in both,
  `rv32ui`/`ua`/`zb*` as before, with the same documented gaps as their
  baselines (`fence_i`, `ma_data`).
- `make boot-board` passes in the Linux board build (the `board-ddr`
  variant). `tools/rvlinux all --board`, the same Linux boot as Step 54
  with the iterative divider, reaches its shell and passes all 17 output
  checks: 245.7M cycles in all, 176M from kernel entry to the prompt.

What it costs: a divide is 33 cycles instead of 1. Kernel entry to the
shell prompt is 176M cycles, 3.5 s at 50 MHz, which is what Step 54
reported without it.

## The clock: FCLK1 at 11.11 MHz

nextpnr's estimate for the core was about 15 MHz, so 50 MHz was out of
reach. The board's oscillator divides only to 12.5 MHz (by 4), where the
16550's integer divisor gives 111,607 baud, 3.1 % slow. That is too
marginal to send 3 MB through. The PS has a better source: its IO PLL runs
at 1000 MHz (`ps7_init`'s `IO_PLL_CTRL` FDIV 30 on a 33.33 MHz crystal),
and FCLK1 divides it by any product of two 6-bit divisors. 1000 / (9 × 10)
= 11.11 MHz, and 11.11 MHz / 16 / 6 = 115,741 baud. That is 0.47 % fast,
the same as 50 MHz / 27, which the board ROM has always used.

- OpenZynq's `ps7_gp0` gains a `fclk1` output (FCLK_CLK1 through its own
  BUFG). Existing designs don't connect it, so it and the BUFG are
  optimised away there.
- `fpga_top_linux` runs `soc_boot` and HP0 on it and has no PL clock pin
  any more. LED2's heartbeat is bit 23 (0.75 s).
- The PS program sets `FPGA1_CLK_CTRL` to `0x00a00900` right after
  `ps7_init` (which leaves FCLK1 at 125 MHz), before the PL's core is
  released or, in the QSPI boot, programmed. It prints the value it reads
  back.
- The board build has its own ROM and device tree, in
  `build/boot/linux-board/`, built with `PLAT_CLOCK_HZ=11111111
  UART_DIVISOR=6`. `platform.h` takes `PLAT_CLOCK_HZ` from the command
  line now. The timebase, the CPU's and UART's `clock-frequency` and
  `current-speed` follow it. U-Boot and Linux need no change: both derive
  their UART divisor and timer rate from the device tree. `fpga_top_boot`
  keeps the 50 MHz ROM in `build/boot/board/`.
- nextpnr is told `--freq 11.11` (OpenZynq's `project.mk`). It applies
  that to every clock, so FCLK0's figure has to be read against its real
  100 MHz.

**What the slower clock costs.** Everything takes 4.5 times as long in
seconds as at 50 MHz: the shell comes up about 26 s after U-Boot starts,
and a boot from flash spends about 22 s in the ROM checking and copying
the 3.2 MB image (Step 56's 4.8 s at 50 MHz), about 50 s from power to
shell. Serial loading is unchanged: it is set by the 115200 baud line.

**The tick.** At 11.11 MHz the kernel's 250 Hz tick was 44,444 cycles. In
the board simulation Linux stopped printing after its clocksource switch:
it spent its time servicing timer interrupts through the SBI, on 2 KiB
caches. The kernel is now `CONFIG_HZ=100`, 111,111 cycles a tick, still
fewer than the 200,000 that 250 Hz gave at 50 MHz.

## Less logic

`ZB_EXT=0` (on `soc_boot`) and `BPRED=0` in the board top drop
Zba/Zbb/Zbc/Zbs and the branch predictor. Nothing that boots uses Zb*:
the kernel has `CONFIG_RISCV_ISA_ZBA/ZBB/ZBC` off, U-Boot has
`CONFIG_RISCV_ISA_ZBB` off, and the userland is built for `rv32ima`. The
board's device tree, built with `-DPLAT_NO_ZB`, advertises
`rv32ima_zicntr_zicsr_zifencei_zihpm`, so nothing is told otherwise. The
predictor only ever saved cycles. Together with `DIV_ITER`, that takes the
design from 71 % of nextpnr's LUT sites to 36 %, and its flip-flops from
7,996 to 4,281.

### Checks of the board configuration

The simulation variant `board-ddr` (`tools/rvboot`) now is the board
build exactly: the 11.11 MHz ROM, divisor 6, `DIV_ITER=1`, `ZB_EXT=0`,
`BPRED=0`, 64 MiB over a 64-bit HP0-shaped port.

| check | result |
|---|---|
| `make boot-board` | ALL PASS, both builds: `board` (fpga_top_boot, unchanged) and `board-ddr` |
| `tools/rvtests --core pipe_c_uni_board`, the board's core behind caches | `rv32ui` 41/41, `rv32um` 8/8, `rv32ua` 10/10 (the documented `ma_data` gap as before) |
| `rvlinux oz-sim`: the board top through its pins, on OpenZynq's own `ps7_gp0` (with `fclk1`) and the PS7 model's 11.11 MHz FCLK1 | PASS: ID read, run written, a bad image rejected, `libc_demo` from DDR; HP0 1,268 reads + 467 writes, 0 protocol errors; the core ran 0 cycles early |
| `make ps-test`, and the PS program built against the Vivado `ps7_init` | ALL PASS; builds |
| `make boot` (the other configurations) and `make linux-fast` (the 50 MHz simulation, now with the 100 Hz kernel) | ALL PASS; `linux-fast` 207.1M cycles, from 232.3M with fewer ticks |
| U-Boot + Linux on the board configuration (`rvlinux run --uboot --board`), with the 100 Hz kernel | LINUX: ALL PASS, 20 output checks; the shell 290M cycles after the ROM starts U-Boot: 26 s at 11.11 MHz (with the 250 Hz kernel it stalled after the clocksource switch, above) |

## What stopped the first attempt

1. **nextpnr-xilinx's post-placement repair.** After placing, its
   `fixupPlacement` looks for cells the placer left on an invalid BEL, such
   as a LUT6 on a 5-input LUT site, and moves each to the nearest valid
   free one. At this density it logs `post-place repair: no valid
   placement for …` for 88 cells and leaves them. The router then can't
   find a wire for their input (`No wire found for port A1`) and aborts.
   Plain ABC instead of ABC9 gives the same error at 63 % of the sites, so
   it is not an ABC9 artefact. I read the source of the repair
   (`xilinx/arch_place.cc`, tag 0.9.3) but did not find a way around it.
2. **Timing.** nextpnr's estimate after placement is 15.5 MHz for the core
   clock (`u_ps7.hp0_aclk`, which is the 50 MHz PL oscillator, because the
   core and `S_AXI_HP0` share it), against 105 MHz for the GP0 clock.
   The long path is the whole EX stage in one cycle: forwarding, the ALU,
   the address, the D-TLB lookup and the D-cache tag compare. The
   estimate is before routing, and prjxray's timing data is conservative,
   but a factor of three is not within what routing recovers. The core
   would need a slower clock, with `PLAT_CLOCK_HZ`, the UART divisor and
   the device tree to match, or a shorter critical path.

The second attempt answered both: less logic left the repair room to
relocate every stranded cell, and the slower clock put the core inside its
timing.

## Reproducing the toolchain build

OpenZynq's `docker/Dockerfile` does not build today, for reasons that have
nothing to do with this design:

- It downloads openXC7's installer script from `main`, which has since
  moved to a different engine (Bazel, a himbaechel build of nextpnr), so
  the image no longer holds `nextpnr-xilinx`, `bbasm` and `bbaexport.py`
  where the Makefile expects them. Pinning the installer URL to commit
  `0d8d6d84cb40fd546719df225ba3717165b2617f` (the one that matches the
  versions the Dockerfile's own comments name) gives the image the Makefile
  was written for. That change is in the OpenZynq checkout.
- Behind a TLS-intercepting proxy, the build needs the proxy's CA in every
  stage and `--network host`; it is a sandbox matter, not part of the repo.

## Files

`rtl/alu.v` (`div_iter`, and `DIV_ITER` on `alu`), `rtl/cpu_pipe_u.v`,
`rtl/soc_boot.v` (`DIV_ITER`, `ZB_EXT`), `rtl/fpga_top_linux.v` (FCLK1,
the board's parameters), `constraints/openzynq_linux.xdc` (no clock pin),
`sw/boot/platform.h` and `sw/boot/rvfs-soc.dts` (`PLAT_CLOCK_HZ`,
`PLAT_NO_ZB`), the Makefile's `build/boot/linux-board/` ROM,
`sw/linux/board/ps/main.c` (`fclk1_init`), `sw/linux/kernel.config`
(`CONFIG_HZ=100`), `tb/div_iter_tb.v`, `tb/ps7_hp0_model.v` (FCLK1),
`tb/fpga_top_linux_tb.v`, `tb/rvtest_pu_tb.v` and `tb/rvtest_pc_tb.v`
(`RVT_DIV_ITER`, `RVT_BOARD`), `tools/rvtests` (`pipe_u_div`,
`pipe_c_uni_div`, `pipe_c_uni_board`), `tools/rvboot` (`board-ddr`),
`tools/rvlinux` (the new ROM; `oz-export` keeps `prebuilt/`). In OpenZynq:
`rtl/ps7_gp0.v` (`fclk1`) and `docker/Dockerfile` (the installer pinned).
`make div-iter`.
