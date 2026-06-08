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

## Directory layout

```
riscv-cpu-tutorial/
├── README.md          <- this file
├── docs/              <- the tutorial, one markdown file per step
├── rtl/               <- synthesizable hardware (the CPU itself)
├── tb/                <- testbenches (simulation-only checking code)
├── sw/                <- assembly programs the CPU will run
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
- 🟡 **AXI4-Lite / AXI-HP master to the PS** — bus-to-AXI adapter + stall-capable memory to reach the Zynq DDR and PS peripherals.
- 🔴 **Tape-out flow** — push RTL through OpenLane + SkyWater sky130 to a GDSII layout.

### Deeper OS
- 🟡 **Memory-isolated processes** — merge the MMU (22/24) with the scheduler (25): per-task page tables, switch `satp` on context switch.
- 🟡 **Supervisor mode + `medeleg`/`mideleg`** — delegate faults/interrupts to an S-mode kernel.
- 🟡 **Instruction-fetch translation + TLB** — translate fetch (today only data is), cache translations.
- 🔴 **Port xv6-riscv, then Linux** — xv6 is the realistic next OS; Linux needs S-mode, full MMU+TLB, atomics, device tree.

### Make it fast (microarchitecture)
- ✅ **Branch predictor** — BTB + 2-bit saturating counters on the pipelined core (Step 32): 3544 flushes → 879 mispredictions on the demo, ~1.3x fewer cycles. Return-address stack is the natural follow-up.
- 🟡 **I-cache / D-cache** — the payoff of understanding BRAM latency; prerequisite for DDR.
- 🟡 **Unify the cores** — fold atomics + MMU into the pipelined core so the fast path has every feature.
- 🔴 **Superscalar / out-of-order** — Tomasulo, register renaming, reorder buffer.

### Broaden the ISA
- 🟢 **C (compressed)** — 16-bit instructions; variable-length, unaligned fetch.
- 🟡 **F/D (floating point)** — an FPU, the float regfile, `fcsr`.
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
- 🟢 **Real libc** — swap the shims for newlib/picolibc (full `printf`, `malloc`).
- 🟡 **Bootloader + device tree** — load/run arbitrary programs; Linux prerequisite.

### Peripherals & interrupts
- ✅ **UART interrupts + receive-to-idle** — machine external interrupt (cause 11) wired to a configurable UART, with STM32-style IDLE-line detection to receive whole variable-length messages (Step 31).
- ✅ **Interrupt controller (PLIC)** — per-source priority / enable / threshold / claim-complete multiplexing several lines into one `MEIP` (Step 33). Surfaced and fixed a read-side-effect bus bug via a new `dmem_re` read strobe.
- 🟡 **Richer peripherals** — SPI/I2C masters, GPIO with edge interrupts, a PWM/timer-capture block — each behind the same MMIO + IRQ pattern.

### For fun / applications
- 🟢🟡 **Doom (bare-metal RV32)**, a tiny TCP stack (lwIP), a shell, or framebuffer graphics — proof it's a *computer*.
