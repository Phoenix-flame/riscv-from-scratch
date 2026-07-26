# Building a RISC-V CPU from Scratch (Simulation)

A step-by-step tutorial that builds a working **RV32I** single-cycle
processor in Verilog, simulated with **Icarus Verilog** and inspected with
**GTKWave**, on **Ubuntu 24.04**. Every module is delivered with a
self-checking testbench, so you always know whether a step works.

> _Developed collaboratively with Claude (Anthropic) — RTL, tests, software,
> and docs._

## What you will end up with

A processor that can execute real RISC-V machine code, including:

- Integer arithmetic / logic (`add`, `sub`, `and`, `or`, `xor`, `slt`, ...)
- Immediate instructions (`addi`, `andi`, `slli`, ...)
- Loads and stores (`lw`, `sw`)
- Branches and jumps (`beq`, `bne`, `blt`, `jal`, `jalr`)
- Upper-immediate instructions (`lui`, `auipc`)

It will run a small assembly program (computing a sum / a Fibonacci
sequence) and we will watch the registers change in the waveform viewer.

## Roadmap

| Step | Document | What we build | Status |
|------|----------|---------------|--------|
| 00 | `docs/00-overview.md` | The plan, the ISA, the architecture | written |
| 01 | `docs/01-environment-setup.md` | Install & verify the toolchain | written |
| 02 | `docs/02-verilog-crash-course.md` | Verilog refresher tied to real code | written |
| 03 | `docs/03-alu.md` | The ALU + testbench | **done & tested** |
| 04 | `docs/04-register-file.md` | The 32-register file | **done & tested** |
| 05 | `docs/05-memories.md` | Instruction & data memory | **done & tested** |
| 06 | `docs/06-immediate-and-control.md` | Immediate decode + control unit | **done & tested** |
| 07 | `docs/07-datapath.md` | Wiring the single-cycle datapath | **done & tested** |
| 08 | `docs/08-program-and-run.md` | Assemble a program & run it | **done & tested** |
| 09 | `docs/09-debugging-in-gtkwave.md` | Reading waveforms like a pro | **done & tested** |
| 10 | `docs/10-running-c.md` | Bonus: compile C and run it | **done & tested** |
| 11 | `docs/11-peripherals.md` | Bonus: UART, timer & a bus (SoC) | **done & tested** |
| 12 | `docs/12-initialized-data.md` | Bonus: string/array constants in RAM | **done & tested** |
| 13 | `docs/13-printf-without-libc.md` | Bonus: printf/snprintf via a mini-lib | **done & tested** |
| 14 | `docs/14-fpga-zynq.md` | Bonus: real UART + synthesizable top for Zynq | **done & tested** |
| 15 | `docs/15-interrupts.md` | Bonus: CSRs, traps & a timer interrupt | **done & tested** |
| 16 | `docs/16-mul-div.md` | Bonus: multiply/divide (RV32M) | **done & tested** |
| 17 | `docs/17-pipelining.md` | Bonus: a 5-stage pipelined core | **done & tested** |
| 18 | `docs/18-illegal-instruction-and-isa-faq.md` | FAQ: assembler vs hardware + illegal-instruction trap | **done & tested** |
| 19 | `docs/19-ecall-syscalls.md` | Bonus: `ecall` system calls + a syscall ABI | **done & tested** |
| 20 | `docs/20-pipelined-exceptions.md` | Bonus: precise exceptions/interrupts in the pipeline | **done & tested** |
| 21 | `docs/21-privilege-modes.md` | Bonus: machine/user privilege levels + protection | **done & tested** |
| 22 | `docs/22-mmu-virtual-memory.md` | Bonus: Sv32 MMU — virtual memory & page faults | **done & tested** |
| 23 | `docs/23-synthesizable-fpga.md` | Bonus: synthesizable BRAM SoC for Zynq-7010 (multi-cycle core) | **done & tested** |
| 24 | `docs/24-synthesizable-mmu.md` | Bonus: synthesizable Sv32 MMU (multi-cycle page-table walker, BRAM page tables) | **done & tested** |
| 25 | `docs/25-preemptive-multitasking.md` | Bonus: preemptive multitasking — timer-driven two-task scheduler | **done & tested** |
| 26 | `docs/26-atomic-extension.md` | Bonus: RV32A atomic extension (LR/SC + AMOs) for locks & synchronization | **done & tested** |
| 27 | `docs/27-freertos.md` | Bonus: running FreeRTOS (64-bit CLINT + RTOS SoC + port scaffolding) | **done & tested** |
| 28 | `docs/28-freertos-fpga.md` | Bonus: FreeRTOS on the synthesizable Zynq-7010 SoC (BRAM, real UART) | **done & tested (sim)** |
| 29 | `docs/29-debug-stub.md` | Bonus: debug stub — hardware debug module (halt/step/breakpoints) + gdb RSP server | **done & tested** |
| 30 | `docs/30-configurable-uart.md` | Bonus: configurable UART with RX path (runtime baud/data/parity/stop) on Zynq-7010 | **done & tested (sim)** |
| 31 | `docs/31-uart-interrupts.md` | Bonus: UART interrupts + receive-to-idle (machine external interrupt, IDLE-line detection) on Zynq-7010 | **done & tested (sim)** |
| 32 | `docs/32-branch-predictor.md` | Bonus: branch predictor (BTB + 2-bit saturating counters) on the pipelined core, with measured misprediction rate | **done & tested (sim)** |
| 33 | `docs/33-plic.md` | Bonus: PLIC interrupt controller — per-source priority / enable / threshold / claim-complete multiplexing several lines into one `MEIP` | **done & tested (sim)** |
| 34 | `docs/34-compressed.md` | Bonus: the C extension — 16-bit instructions, halfword-aligned PCs, word-straddling fetch; ~29% smaller code, verified against the rv32im build | **done & tested (sim)** |
| 35 | `docs/35-floating-point.md` | Bonus: the F extension — single-precision FPU (IEEE-754 round/guard/sticky, 5 rounding modes), the `f0`–`f31` float register file, `fcsr`; runs real `-march=rv32imf` gcc output, bit-exact vs host float32 (subnormals flushed) | **done & tested (sim)** |
| 36 | `docs/36-axi-master.md` | Bonus: an AXI4-Lite master to the Zynq PS — a stall-capable bus (`dmem_ready`), a 5-channel bus-to-AXI adapter, and a wait-state PS/DDR slave model; the core stalls on variable-latency accesses and reaches PS DDR + peripherals | **done & tested (sim)** |
| 37 | `docs/37-real-libc.md` | Bonus: a real C library (picolibc) — full `printf` + `malloc`/`free` via a tiny retarget (UART `putc`, heap symbols, `_exit`); byte-exact demo, and the FreeRTOS build swapped off the shims onto picolibc | **done & tested (sim)** |
| 38 | `docs/38-isolated-processes.md` | Bonus: memory-isolated processes — merge the Sv32 MMU (22/24) with the preemptive scheduler (25): a page table per task, `satp` reloaded on each context switch; two tasks share VA `0x1000` but land in different physical pages | **done & tested (sim)** |
| 39 | `docs/39-supervisor-delegation.md` | Bonus: supervisor mode + trap delegation — add S-mode (`cpu_mc_s`, `csr_s`) with `medeleg`/`mideleg`; a user `ecall`, an illegal instruction, and a software interrupt are delivered straight to an S-mode kernel, while an `ecall` from S still reaches M | **done & tested (sim)** |

## Directory layout

```
riscv-cpu-tutorial/
├── README.md          <- this file
├── docs/              <- the tutorial, one markdown file per step
├── rtl/               <- synthesizable hardware (the CPU itself)
├── tb/                <- testbenches (simulation-only checking code)
├── sw/                <- assembly programs the CPU will run
├── tools/             <- helper tools (rvsim: run a program & dump state)
└── build/             <- compiled simulations + .vcd waveforms (generated)
```

## Quick start (after reading step 01)

```bash
# Compile and run the ALU test
iverilog -g2012 -Wall -o build/alu_tb.vvp rtl/alu.v tb/alu_tb.v
vvp build/alu_tb.vvp

# Open its waveform
gtkwave build/alu_tb.vcd
```

Start with `docs/00-overview.md`.

## Run a program & inspect the CPU (`rvsim`)

`tools/rvsim` is a small command-line front-end that loads a program onto
the CPU, runs it, and prints the final register file, PC and memory —
without hand-writing a testbench. It accepts a raw **`.bin`**, a
**`.hex`** (`$readmemh` word image), or an **`.elf`** (converted for you).

```bash
# Run a raw binary on the single-cycle core and show the registers
tools/rvsim path/to/prog.bin

# Run the peripheral demo on the SoC (real UART output + self-halt)
tools/rvsim sw/socdemo.hex --core soc --data sw/socdemo_data.hex

# Compiled ELF, trace each cycle, and dump 16 data words from address 0
tools/rvsim prog.elf --trace --cycles 200 --mem 0:16

# Same thing through make
make run BIN=path/to/prog.bin
make run BIN=sw/socdemo.hex CORE=soc DATA=sw/socdemo_data.hex
```

Sample output:

```
──────────────────────────────────────────────────────────────
RISC-V CPU state   (cpu: single-cycle core (rtl/cpu.v))
──────────────────────────────────────────────────────────────
  program : prog.bin
  cycles  : 13     halt: PC stalled (spin loop)
  pc      : 0x00000024     instr: 0x0000006f

  x0  zero 0x00000000   x8    s0 0x00000000   x16   a6 0x00000000   x24   s8 0x00000000
  x1    ra 0x00000005   x9    s1 0x00000000   x17   a7 0x00000000   x25   s9 0x00000000
  ...
```

Useful flags (`tools/rvsim --help` for all):

| Flag | Meaning |
|------|---------|
| `--core {cpu,soc}` | single-cycle core (default) or full SoC with UART/timer/halt |
| `--cycles N` | max cycles before stopping (default 200000) |
| `--trace` | print `pc`/`instr` for every retired cycle |
| `--mem START:COUNT` | hex-dump `COUNT` data words from byte `START` (e.g. `0x40:8`) |
| `--data FILE` | preload data memory (auto-derived from an `.elf`) |
| `--dec` | also show registers as signed decimals |
| `--vcd` | also write a GTKWave waveform under `build/` |

The run stops on its own when the program spins (`j .`), runs off the end,
halts via the SoC's syscon device, or hits the cycle cap. Both cores have a
4 KB (1024-instruction) instruction memory, so this is aimed at the small
bare-metal programs in `sw/`.

### Interactive mode — a stepping debugger

Run `rvsim` with **no program** (or pass `-i`) and it drops into an
interactive shell instead of a one-shot dump — a little gdb-for-the-tutorial
where you step the CPU cycle by cycle and watch the registers change, with
inline disassembly, breakpoints and a full trace.

```bash
tools/rvsim                    # empty shell — then: load sw/sum.hex
tools/rvsim -i sw/sum.elf      # load a program and start stepping
make sim BIN=sw/sum.hex        # same thing through make
```

```
rvsim 6/49 ❯ step
● cycle 7/49  pc 0x0000000c  00315863  bge sp,gp,0x1c
  Δ x2 sp  0x00000002 → 0x00000003  (3)

rvsim 7/49 ❯ break 0x1c        # stop when PC reaches the store
rvsim 7/49 ❯ continue
● cycle 44/49  pc 0x0000001c  00102023  sw ra,0(zero)
  Δ x1 ra  0x00000003 → 0x00000037  (55)
```

It works by re-running the deterministic simulation to a cycle *cursor*, so
`step`, `back`, `goto` and `continue` all just move that cursor — no waveform
digging required. Type `help` for the full command list; the highlights:

| Command | What it does |
|---------|--------------|
| `load FILE` | load a `.bin`/`.hex`/`.elf` and reset to cycle 0 |
| `step [N]` / `back [N]` | advance / rewind N cycles, showing what changed |
| `continue` | run to the next breakpoint (or the natural halt) |
| `goto CYCLE` / `reset` | jump the cursor to an absolute cycle / to 0 |
| `break PC` / `breaks` / `delete` | set / list / remove PC breakpoints |
| `regs` / `mem START:COUNT` / `trace [N]` | inspect registers / RAM / history |
| `core {cpu,soc}` / `cycles N` / `dec` | switch core / cap / decimal display |
| `vcd` | write a GTKWave waveform of the current program |

Inline disassembly and breakpoints need a `riscv64-unknown-elf-objdump` on
`PATH`; without it the shell still steps and shows the raw instruction word.

## Acknowledgements

This project was developed collaboratively with **Claude**, Anthropic's AI
assistant. Claude helped design and write the RTL, the self-checking
testbenches, the bare-metal software and toolchain flow, and all of the
step-by-step tutorial documents — with each module built bottom-up and verified
in simulation along the way.

## Future directions (roadmap beyond Step 27)

A menu of where this project can go next, grouped by goal. Rough difficulty:
🟢 weekend–week · 🟡 multi-week · 🔴 multi-month.

### Onto real silicon
- ✅ **Run FreeRTOS on the Zynq-7010** — synthesizable BRAM SoC (`soc_rtos_fpga` + `fpga_top_rtos`), real UART, verified in sim (Step 28). Vivado bitstream is the remaining manual step.
- ✅ **AXI4-Lite master to the PS** — a stall-capable core (`cpu_mc_stall` waits on `dmem_ready`), a 5-channel bus-to-AXI4-Lite adapter, and a `soc_axi` that windows `0x4000_0000` out to the PS (Step 36). Verified against a wait-state AXI slave modelling PS DDR + a peripheral; reads/writes round-trip correctly through the stalls. Full AXI4 bursts (AXI-HP for DDR bandwidth) wait on a cache or DMA engine to generate them.
- 🔴 **Tape-out flow** — push RTL through OpenLane + SkyWater sky130 to a GDSII layout.

### Deeper OS
- ✅ **Memory-isolated processes** — per-task page tables with `satp` reloaded on every context switch (Step 38). Two preempted user tasks share the same virtual addresses (private page at VA `0x1000`, stack at `0x2000`) yet map to different physical pages, so neither can touch the other's memory; the MMU enforces it, the kernel just hands each task its own address space. Built on the unmodified synthesizable MMU SoC. A TLB (and the `sfence.vma` it would require) is the natural next step.
- ✅ **Supervisor mode + `medeleg`/`mideleg`** — a third privilege level (S) with per-cause trap delegation (Step 39). Two bit-masks route traps taken below machine mode: a delegated cause vectors straight to the S-mode handler at `stvec`, updates the supervisor trap CSRs, and enters S — machine mode never runs. The demo delegates a user `ecall`, an illegal instruction, and a supervisor software interrupt to an S-mode kernel, while a non-delegated `ecall` from S still reaches M. `sstatus`/`sie`/`sip` are masked views of the machine registers; built on a fresh `cpu_mc_s`/`csr_s` so the rest of the regression is untouched. Delivering the MMU core's page faults to S the same way is the next step.
- 🟡 **Instruction-fetch translation + TLB** — translate fetch (today only data is), cache translations.
- 🔴 **Port xv6-riscv, then Linux** — xv6 is the realistic next OS; Linux needs S-mode, full MMU+TLB, atomics, device tree.

### Make it fast (microarchitecture)
- ✅ **Branch predictor** — BTB + 2-bit saturating counters on the pipelined core (Step 32): 3544 flushes → 879 mispredictions on the demo, ~1.3x fewer cycles. Return-address stack is the natural follow-up.
- 🟡 **I-cache / D-cache** — the payoff of understanding BRAM latency; prerequisite for DDR.
- 🟡 **Unify the cores** — fold atomics + MMU into the pipelined core so the fast path has every feature.
- 🔴 **Superscalar / out-of-order** — Tomasulo, register renaming, reorder buffer.

### Broaden the ISA
- ✅ **C (compressed)** — RV32IMC core (`cpu_mc_c` + `rvc_expand`, Step 34): 1:1 expansion to base instructions, halfword PCs, straddling fetches resolved in one extra cycle. Same program, 424 → 302 code bytes. A fetch buffer is the natural follow-up.
- ✅ **F (single-precision floating point)** — single-precision FPU, the `f0`–`f31` float register file, and `fcsr` (Step 35): runs real `-march=rv32imf` gcc output and matches host float32 bit-for-bit across the normal range (367-point unit test + compiled-program integration test). Subnormals are flushed to zero. Double precision (D) and the fused multiply-add family are the natural follow-ups.
- 🟡 **Zb (bit-manip)** — small, high-value. **V (vector)** — deep and modern.
- 🔴 **RV64** — widen to 64-bit; required for Linux.

### Rigorous correctness
- 🟢 **riscv-tests** — official per-instruction suite against the core.
- 🟡 **Differential testing vs Spike** — same program on core + reference sim, compare state each step.
- 🟡 **Benchmark** — Dhrystone / CoreMark, report DMIPS/MHz and CoreMark/MHz.
- 🔴 **Formal verification** — riscv-formal + SymbiYosys.

### Multi-core / SMP
- 🔴 **Two harts** — duplicate the core with distinct `mhartid`, shared memory + arbiter, cross-core LR/SC (where `aq`/`rl` finally matter); then SMP FreeRTOS / Linux.

### Tooling & ecosystem
- ✅ **Debug stub** — hardware debug module (halt/step/4 HW breakpoints/reg+mem access) + gdb RSP server (Step 29); transport bridge to live gdb is the remaining glue.
- ✅ **Real libc** — picolibc with full `printf` and `malloc`/`free` (Step 37). The platform contract is three hooks: a UART `putc` for `stdout`, `__heap_start`/`__heap_end` for the allocator, and `_exit`. A byte-exact demo (`make libc`) checks formatting + heap + `string.h`, and the FreeRTOS build now links picolibc with the header shims and the `firmware.c` mini-printf retired (verified running through real `printf`).
- 🟡 **Bootloader + device tree** — load/run arbitrary programs; Linux prerequisite.

### Peripherals & interrupts
- ✅ **UART interrupts + receive-to-idle** — machine external interrupt (cause 11) wired to a configurable UART, with STM32-style IDLE-line detection to receive whole variable-length messages (Step 31).
- ✅ **Interrupt controller (PLIC)** — per-source priority / enable / threshold / claim-complete multiplexing several lines into one `MEIP` (Step 33). Surfaced and fixed a read-side-effect bus bug via a new `dmem_re` read strobe.
- 🟡 **Richer peripherals** — SPI/I2C masters, GPIO with edge interrupts, a PWM/timer-capture block — each behind the same MMIO + IRQ pattern.

### For fun / applications
- 🟢🟡 **Doom (bare-metal RV32)**, a tiny TCP stack (lwIP), a shell, or framebuffer graphics — proof it's a *computer*.
