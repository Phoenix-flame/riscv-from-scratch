# Step 45 — `make menuconfig`: a RISC-V core generated for OpenZynq

Forty-four steps built a lot of hardware: four core organisations, seven ISA
and privilege features, an MMU, caches and a predictor. They were spread over
a dozen top-level modules, and each one was wired into its own testbench by
hand. Getting *one particular* RISC-V onto a real board meant knowing which
files that needed, which parameters to set, and how to wrap it for the FPGA
flow.

This step turns that into a menu. Pick the features, and get a complete
project for [OpenZynq](https://github.com/Phoenix-flame/OpenZynq), the
open-toolchain (Yosys → nextpnr-xilinx → bitstream) workspace for the
Artemis Karia **Mitra-7010** (`xc7z010`):

```
make menuconfig                  # pick the core and its features -> .config
make rvgen                       # -> build/oz/projects/<name>/, simulated
make oz-export OZ=../OpenZynq    # copy it into an OpenZynq checkout

# then, in OpenZynq:
make sim  PROJECT=<name>         # the same self-test, under OpenZynq's flow
make bit  PROJECT=<name>
make prog PROJECT=<name>         # standalone   |   make run PROJECT=<name>  (PS-attached)
```

The menu is Kconfig, the configuration language of Linux and Zephyr, through
[Kconfiglib](https://github.com/ulfalizer/Kconfiglib). Kconfiglib is vendored
unmodified in `tools/kconfig/` (ISC licence), so nothing needs installing.

## The menu

```
Project            name; standalone or PS-attached; UART pin + baud
Core               5-stage pipeline  |  multi-cycle
  ISA extensions   M, A, Zba/Zbb/Zbc/Zbs, V + VLEN (pipeline) -- or C / F (multi-cycle)
  Privilege        U, S + delegation, Sv32 MMU (TLB entries)     (pipeline)
  Branch predictor BTB + 2-bit counters, size                     (pipeline)
Memory             IMEM / DMEM KiB; I/D caches, line size, lines  (caches: pipeline)
Peripherals        machine timer, GPIO (LEDs + buttons)
Firmware           the configuration's self-test, or your own .hex
```

The features do not all live on one core. The pipeline (`cpu_pipe_u`) has A,
the privilege modes, the MMU, the predictor and the caches. C and F exist only
on the multi-cycle cores (`cpu_mc_c`, `cpu_mc_f`). So the menu asks for the
**core first**, and Kconfig's `depends on` offers only what that core can do:

- choose *multi-cycle* and the A, U/S, MMU, predictor and cache entries
  disappear, M becomes fixed, and C or F appear;
- choose *pipeline* and C and F are not offered.

You cannot ask for a combination that does not exist.

### A feature that is off is not built

`cpu_pipe_u` took one parameter per feature. A parameter that only hid a
feature would cost area and mislead the menu, so each one removes the
hardware:

| Parameter | When 0 |
|---|---|
| `M_EXT` | `alu` builds no multiplier or divider; MUL/DIV decode as illegal |
| `A_EXT` | AMO/LR/SC decode as illegal; the MEM-stage AMO sequencer is constant-folded away |
| `MMU` | the I-TLB, D-TLB and walker are not instantiated (`generate`); `satp` reads 0 |
| `HAS_S` | `medeleg`/`mideleg` read 0, S-level CSRs and `sret` are illegal, no delegation |
| `HAS_U` | `mstatus.MPP` can only hold M (WARL), so `mret` can never leave M |
| `BPRED` | no predictor tables; IF predicts not-taken |

The privilege parameters live in `csr_s`, which gains `HAS_S` / `HAS_U` /
`HAS_SATP`. Every parameter defaults to on, so Steps 42–44, and `cpu_mc_s`
which shares `csr_s`, are unchanged; their tests still pass. The self-test
checks the "off" side too. In a configuration without M, a `mul` must trap as
illegal. Without A, an `amoadd` must trap without touching memory. Without U,
`MPP` must refuse to hold U.

## One SoC for every core

`rtl/oz/oz_rv_soc.v` puts any of the four cores behind one memory map:

| Address | Device |
|---|---|
| `0x0000_0000` | IMEM (fetch) / DMEM (data): block RAM, Harvard |
| `0x1000_0000` | console: +0 TX, +4 STATUS (bit 0 = ready) |
| `0x1001_0000` | machine timer (`mtime`, `mtimecmp`, interrupt) |
| `0x1002_0000` | GPIO: +0 the two LEDs, +4 the two buttons |
| `0x2000_0000` | SYSCON: a write halts; the value is the exit code |

That is the map every SoC in this project already used, so existing programs
run unchanged.

The memory side is where the cores differ:

- The **multi-cycle** cores were written against registered block RAM in
  Step 23. Their buses go straight onto the RAM ports.
- The **pipeline** has ready/valid ports (Step 42). With caches, it gets
  `icache` + `dcache` (Step 43). Without them, it gets the single-word
  `mem_bridge`.

In both pipeline cases the line traffic ends in `oz_burst_mem`. This is
`mem_slow`'s interface on top of a real RAM port: one word per cycle, plus one
cycle for the registered read.

The memories are `oz_dpram`: two ports and **one** clock. Port A belongs to
the core. Port B belongs to the host, through which the PS loads programs in
PS-attached builds. A RAMB36 can clock its two ports separately, but Yosys
0.33 refuses to infer a true dual-port RAM from a two-clock description. So
both ports share the core clock, and the host's writes cross into that domain
first (below). The single-clock form maps to block RAM on every Yosys version
tried.

## Two ways onto the board

**Standalone** (`SYS_STANDALONE`):

- The core runs from the 50 MHz PL oscillator (U18). Its firmware is baked
  into the block RAMs through `$readmemh`, so `make prog` and it runs.
- The console byte stream drives `oz_uart` (`uart_tx` with valid/ready) onto
  a header pin. The default is `J18`, JM1 pin 21, in 3.3 V bank 35. Watch it
  with any 3.3 V USB-serial adapter.
- K1 (U19) resets the core.

**PS-attached** (`SYS_PS`):

- The Cortex-A9 drives everything over M_AXI_GP0, through OpenZynq's
  `ps7_gp0` and `axi3_to_axilite`, to `oz_host`, an AXI4-Lite slave at
  `0x4000_0000`.
- The generated `ps/main.c` first checks that the bitstream is the
  configuration it was built for (a CRC of the resolved `.config`, compiled
  into both). It then holds the core in reset and writes the firmware into the
  IMEM and DMEM windows. After reading the image back, it sets `CTRL.run` and
  copies every byte the RISC-V prints to UART0, the on-board CH340. When the
  core halts, it reports the exit code.
- No extra hardware is needed.

The core still runs on the 50 MHz PL oscillator in this mode. The AXI side
runs on FCLK0 (100 MHz), so `oz_host` crosses domains in three ways:

| Signal | Crossing |
|---|---|
| `CTRL.run` → core reset | two-flop synchroniser |
| halted / exit code → PS | two-flop synchroniser on `halted`; the exit code is sampled once `halted` arrives, long after it settled |
| console → PS | `oz_async_fifo`: Gray-coded pointers, 64 bytes |
| PS ↔ memories | toggle request/acknowledge, one word per handshake, through the RAMs' port B in the core domain |

## What gets generated

`tools/rvgen/rvgen.py` resolves `.config` through the same Kconfig file, so
defaults and dependencies apply exactly as the menu showed them. It then
writes:

```
projects/<name>/
  project.mk           TOP, SRCS, SIM_TOP, SIM_SRCS, XDC; SYNTH_OPTS without -nobram
  <name>_top.v         the synthesis top (standalone: pins; PS: PS7 + <name>)
  <name>.v             PS builds: core + oz_host with plain AXI ports, for simulation
  <name>.xdc           clock, K1 reset, LEDs, (buttons), (UART TX)
  tb_<sim top>.v       the self-checking testbench `make sim` runs
  rtl/                 exactly the RTL this configuration needs (copied)
  fw/firmware.hex      the self-test, built for this configuration
  ps/                  PS builds: main.c, rv_firmware.h, Makefile (+ OpenZynq's startup/linker)
  rvconfig             the resolved .config
  README.md            configuration, memory map, build and run steps
```

The **firmware** is `sw/oz/selftest.c` and `start.S`, compiled with the
matching `-march`/`-mabi` against a generated `oz_config.h`. Only the checks
for configured features are compiled in:

- M, A, F;
- compressed code;
- the timer interrupt;
- U-mode `ecall` and the U-mode CSR fault;
- S-mode delegation;
- an MMU remap and an unmapped-VA fault with `mtval`;
- GPIO;
- and the "absent" checks above.

It prints `ALL PASS` and returns the failure count, which becomes the exit
code. U- and S-mode tests use `oz_enter_lower()`, a setjmp/longjmp pair built
from `mret` and the trap vector: it runs a function in a lower mode and
returns to M when that function `ecall`s or faults.

The **testbench** checks the same image the board runs:

- *Standalone:* it decodes the UART pin bit by bit, as an adapter would.
- *PS-attached:* it plays the Cortex-A9 over AXI. It checks the ID and config
  hash, loads the image through the windows, reads it back, starts the core,
  and relays the console.

Either way it passes only on `ALL PASS` with exit code 0. `rvgen --sim` runs
it exactly as OpenZynq's `make sim` would: iverilog from the project root, and
`vvp` inside `build/<name>/`, which is why the testbench reaches its firmware
by a `../../` path.

`oz-export` copies the project into an OpenZynq checkout. A PS build also gets
that checkout's own `startup.S`, `linker.ld` and `xil_io.h`, from
`projects/ps_pl_demo/ps`. Any `ps7_init` the user had already copied in is
kept. The tool refuses to overwrite a directory it did not generate.

## Presets and results

`configs/oz_*_defconfig` are starting points (`make defconfig
DEFCONFIG=configs/...`). `make rvgen-all` generates and simulates every one:

| Preset | Configuration | Self-test |
|---|---|---|
| `oz_full` | pipeline RV32IMA + Zba/Zbb/Zbc/Zbs, M/S/U, Sv32 (4+4 TLB), 32-entry predictor, 1 KiB I$ + 1 KiB D$, standalone | 15/15 (incl. 1 "absent"), 109,586 cycles |
| `oz_full_ps` | the same, PS-attached | 15/15 over AXI |
| `oz_vec` | as `oz_full` without Zbc, plus V (Zve32x, VLEN=128) — Step 47 | 17/17, 123,371 cycles |
| `oz_mu_mmu` | pipeline, M/U + MMU, no S; 2-entry TLBs, 8-entry predictor, 8-line caches of 4 words | 13/13 (incl. 1 "absent") |
| `oz_msu_nommu_ps` | pipeline, M/S/U, no MMU, PS-attached | 12/12 over AXI (incl. 1 "absent") |
| `oz_tiny` | pipeline RV32I, machine mode only, not-taken, no caches, no timer/GPIO, 8+8 KiB | 6/6 (incl. 5 "absent") |
| `oz_mc` | multi-cycle RV32IM | 5/5 (incl. 1 "absent") |
| `oz_mc_c` | multi-cycle RV32IMC (the whole image compressed) | 6/6 (incl. 1 "absent") |
| `oz_mc_f_ps` | multi-cycle RV32IMF, PS-attached | 6/6 over AXI (incl. 1 "absent") |

**Synthesis**, with OpenZynq's own `make synth` and the container's Yosys
0.68, for the `xc7z010` (17,600 LUTs, 35,200 FFs, 60 RAMB36, 80 DSP48):

| Preset | LUTs | of which LUTRAM | FFs | RAMB36 | DSP48 | CARRY4 |
|---|---:|---:|---:|---:|---:|---:|
| `oz_full` | 11,031 | 376 | 4,500 | 12 | 12 | 993 |
| `oz_full_ps` | 11,491 | 388 | 4,906 | 12 | 12 | 1,004 |
| `oz_vec` | ≈ 14,760 † | ≈ 816 | ≈ 5,070 | 12 | 19 | ≈ 1,200 |
| `oz_mu_mmu` | 8,225 | 236 | 2,370 | 12 | 12 | 983 |
| `oz_msu_nommu_ps` | 9,476 | 436 | 4,446 | 8 | 12 | 998 |
| `oz_tiny` | 2,280 | 48 | 1,218 | 4 | 0 | 78 |
| `oz_mc` | 4,521 | 48 | 376 | 8 | 12 | 912 |
| `oz_mc_c` | 4,849 | 48 | 393 | 8 | 12 | 918 |
| `oz_mc_f_ps` | 11,856 | 108 | 837 | 8 | 14 | 2,027 |

LUTs include LUT-RAM (the caches' line arrays, the register files). Every
pipeline preset is a fraction of the part: the full configuration (with all
four Zb groups since Step 46, about +1,450 LUTs) uses 63 % of the LUTs and 13 %
of the flip-flops, and `oz_tiny` uses 13 % of the LUTs.

† `oz_vec` is an estimate: `oz_full` − Zbc + the vector unit synthesized on its
own (Step 47: 3,822 logic LUTs + 440 LUT-RAM, 573 FFs, 7 DSP48 at VLEN=128),
about **84 %** of the LUTs. The whole-SoC run maps it in minutes, but then ABC's
`&mfs` resynthesis pass did not finish in 1.5 hours, the same pathology as the
F core below. That is also why V is a preset of its own and not part of
`oz_full`: together with everything else it leaves little room on a 7010. The
12 DSPs and ~900 carry chains in every preset with M are the multiplier and,
mostly, the **combinational divider**, which is a long carry ripple. `oz_tiny`,
without M, has neither.

The F core (`oz_mc_f_ps`) is the outlier. Its FPU computes divide and square
root as unrolled combinational recurrences (Step 35). It synthesizes, but those
two recurrences make it the largest preset: 11,856 LUTs and 2,027 carry chains,
for a multi-cycle core whose integer side is about 4,500. Mapping them took
ABC 63 of the run's 68 minutes, against 2–5 minutes for every other preset. As
it stands it is not an FPU that belongs on this part. An iterative
divide/square-root datapath, one recurrence step per cycle, is the fix.

Synthesizing every preset found two bugs, both fixed in this step:

- **`M_EXT=0` did not remove M.** `alu` only gated the result mux, and
  synthesis cannot prove `alu_op` never selects the multiply or divide arms,
  so `oz_tiny` still built 12 DSPs and the full divider (5,152 LUTs, 930
  CARRY4). The RV32M units now take constant-zero operands when `M_EXT=0` and
  fold away: 2,264 LUTs, 0 DSP, 78 CARRY4. `M_EXT=1` is logically unchanged,
  and all 12 riscv-tests configurations still pass.
- **`fpu_f` did not synthesize at all.** The square root's two data-dependent
  `while` loops are not a constant-bound iteration, and Yosys stops with
  "non-constant expression in constant function". They are now bounded at 28
  steps each, which is exactly the most the radix-4 recurrence can take from
  `1 << 54`. The results are identical, and the FPU unit, integration and
  riscv-tests (`mc_f` 58/58) all pass.

In OpenZynq itself, the two exported reference projects (`riscv_full`,
`riscv_full_ps`) pass `make sim`, and the PS program builds with
`arm-none-eabi-gcc`.

## Honest status

- **Simulation and synthesis only** (Yosys 0.68, OpenZynq's `make synth`). No placement and routing has been done,
  so timing is unknown (nextpnr-xilinx and the chip database were not
  available here), and nothing has run on a board. The RV32M divider is a
  combinational array and the likely critical path at 50 MHz. A configuration
  that fails timing can drop M (pipeline), or wait for the multi-cycle divider
  that is the natural follow-up.
- C and F exist only on the multi-cycle cores. Putting them in the pipeline (a
  fetch buffer for RVC, the FPU as an EX-stage unit) is what would make the
  menu fully orthogonal.
- The console is output only. There is no RX path to the RISC-V in either
  mode yet.
- In standalone builds, pressing K1 restarts the program with `.data` as the
  previous run left it. Only a reprogram restores the image. PS-attached
  builds reload the image every run.
- The predictor tables are reset, so they map to flip-flops. A 64-entry
  predictor costs about 4k FFs, and the menu says so.

## Takeaway

Kconfig turns "which of forty files, with which parameters" into a menu that
cannot express an impossible core. Under it, every feature became a parameter
that removes hardware, every core sits behind one memory map, and each
generated project carries its own proof: a self-test built for exactly that
configuration, run by a testbench through the same pins or AXI port the board
will use.
