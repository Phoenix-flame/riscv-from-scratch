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
