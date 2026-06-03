# Step 23 — Putting it on real silicon: a synthesizable BRAM SoC for Zynq-7010

Everything so far ran in a *simulator*. This step makes a full-featured core
**synthesizable** so it can run in the programmable logic (PL) of a Zynq-7010
(e.g. a Digilent Zybo Z7-10), entirely from on-chip block RAM, printing over a
real UART pin. (Verified functionally in simulation here; actual place-and-route
needs Vivado, which isn't in this environment.)

## Why the single-cycle core can't just be flashed

Two things in the simulation design don't synthesize, and one forces a real
architectural change:

1. **Simulation-only I/O.** `uart.v` uses `$write` and `syscon.v` uses `$finish`.
   Neither exists in hardware. We swap in the real serializer (`uart_tx.v` /
   `uart_hw.v` from Step 14) and replace the syscon with a **halt register** that
   freezes the CPU and lights an LED.

2. **Combinational-read memory.** `imem.v`/`dmem.v` read combinationally
   (`rdata` valid in the same cycle as the address). That infers as distributed
   LUT RAM, not block RAM. To use **block RAM** you must read **synchronously** —
   the data is valid *one cycle after* the address. And that breaks the
   single-cycle model, because a single-cycle core needs the instruction (and
   load data) within the same cycle.

So going to BRAM forces the core to become **multi-cycle**.

## The multi-cycle core (`cpu_mc.v`)

Same datapath blocks as before (`alu`, `control`, `immgen`, `regfile`, `csr`,
RV32IM + CSRs + traps + privilege), but a small FSM sequences each instruction
so every memory read is registered:

```
FETCH : drive the ROM with PC          (instruction valid next cycle)
EXEC  : instruction is valid -> decode, read regs, ALU, branch, CSR/trap
          - ALU / branch / jump / store / CSR : commit, back to FETCH
          - load : drive the data address, go to MEM
          - trap : redirect to mtvec, back to FETCH
MEM   : load data is valid (registered) -> write back, back to FETCH
```

ALU/branch/store instructions take **2 cycles**; loads take **3**. The block
RAMs are the canonical Xilinx templates — a registered read for the ROM, and a
byte-write registered-read RAM for data:

```verilog
always @(posedge clk) begin           // bram_ram.v
    if (we[0]) mem[a][ 7: 0] <= wdata[ 7: 0];
    // ... per-byte write enables ...
    rdata <= mem[a];                  // registered read  => block RAM
end
```

CSR/trap state only advances on the commit cycle (`csr_we`, `take_trap`, and
`mret` are gated by the `EXEC` state), so an instruction commits exactly once
even though it spans multiple cycles. Sub-word load/store alignment (the byte
lane select and sign/zero extension) moves into the core, since the BRAM is
word-wide with byte-write enables.

## The SoC and the board top

`soc_fpga.v` wires the core to an instruction ROM (BRAM), a data RAM (BRAM), the
real UART, the timer, and the halt register, decoding the same address map as
before. `fpga_top_full.v` is the board top: a 125 MHz clock, a reset button, the
UART TX pin, and a halted-LED. `constraints/zynq7010.xdc` pins those to a Zybo
Z7-10 (with a clear warning to check pins against the board's master XDC, and to
route UART TX to a Pmod pin since the board's USB-UART is wired to the PS).

## Does it fit? Will it run?

The logic is tiny for a 7010 (≈17.6 K LUTs, ≈2.1 Mb BRAM, 80 DSP slices): a
multi-cycle RV32IM core is a few thousand LUTs, the 32×32 multiply maps to a
couple of DSP slices, and the program/data live in a handful of BRAMs. It fits
with room to spare. The slow paths are the **combinational divider** and the
fetch→decode→ALU chain, so you won't hit a high clock — for a teaching core,
driving the SoC from a divided clock (e.g. 50 MHz via an MMCM) is the easy fix,
remembering to set `CLKS_PER_BIT = clk_freq / 115200` for the UART.

## Functional proof (in simulation)

`make fpga-full` builds `sw/fpga_demo.c` (which prints a message and halts —
characters are immediates so no data needs preloading) and runs the *exact*
synthesizable RTL in the simulator, capturing the bytes the CPU writes to the
UART:

```
---- UART output ----
RV32IM on Zynq PL!
[soc] CPU halted, LED on (program signaled done)
```

A separate trap test (`sw/mc_trap.s`) exercises `csrw mtvec`, `ecall`, `csrr/csrw
mepc`, and `mret` on this core and prints `EK`, confirming the CSR/trap/privilege
machinery survives the multi-cycle gating.

## To actually program a board (outside this environment)

1. Create a Vivado project targeting `xc7z010clg400-1`.
2. Add `rtl/{alu,regfile,immgen,control,csr,timer,uart_tx,uart_hw,bram_rom,
   bram_ram,cpu_mc,soc_fpga,fpga_top_full}.v` and `constraints/zynq7010.xdc`.
3. Set `fpga_top_full` as top and its `IMEM_INIT` to your `sw/*.hex` (Vivado
   reads `$readmemh` init files during synthesis to preload the BRAM).
4. Generate bitstream, program the PL, and watch the Pmod UART pin at 115200
   baud. The LED lights when the program halts.

## What's deliberately not here

- **MMU/virtual memory.** The Sv32 MMU's page-table walk is combinational; with
  registered BRAM it must become a multi-cycle walker (with a TLB). That's the
  next hardware step, and a prerequisite for using DDR.
- **DDR / the PS.** Reaching the board's DDR means becoming an AXI master into
  the Zynq PS — a bus adapter plus a stall-capable memory interface. Big enough
  to be its own project.
- **High clock speed / pipelining for Fmax.** The synthesizable *pipelined* core
  (with registered BRAM in the IF and MEM stages, which a pipeline absorbs
  naturally) would clock much faster than this multi-cycle core.

## Takeaway

The leap from "simulates" to "synthesizes" is mostly about **memory timing**:
real block RAM reads a cycle late, and that one fact turns a single-cycle core
into a multi-cycle one. With registered-read BRAMs, a real UART, and a halt LED
instead of `$finish`, the full RV32IM-plus-privilege core is ready to run in the
fabric of a $200 board — no simulator required.
