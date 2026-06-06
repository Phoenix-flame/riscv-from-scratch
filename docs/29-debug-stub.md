# Step 29 — A debug stub: halt, step, breakpoints, and gdb

A debugger needs to reach *inside* a running CPU — stop it, look at registers and
memory, set breakpoints, single-step. This step adds the hardware to do that and
a host-side server that speaks gdb's protocol, so you can eventually
`riscv64-unknown-elf-gdb` into the core.

## The pieces

```
 gdb  <--RSP/TCP-->  gdbstub.py  <--transport-->  debug_module (DMI)  -->  cpu_core_dbg
```

**`rtl/cpu_core_dbg.v`** — the single-cycle core plus a small set of debug hooks:
- a **halt FSM** with `halted` / single-step / "skip breakpoint once on resume";
- **NBP hardware PC breakpoints** (default 4) that halt *before* executing the
  matched instruction;
- while halted, the register file's read/write ports are borrowed so any GPR (and
  the PC) can be read or written;
- the data bus is freed while halted (its write-enable is gated by "running"), so
  the debug module can use it to read/write memory.

The principle that makes it clean: a single `run` signal (`= !halted && !halt_now`)
gates every commit — the PC update, register writes, memory writes, CSR updates,
and trap entry. Halting is just forcing `run` low; the rest of the datapath is
untouched. Single-step is `run` high for exactly one cycle.

**`rtl/debug_module.v`** — a tiny Debug Module exposing a register interface (a
"DMI") that a host drives. Writes to a CONTROL register halt/resume/step; other
registers select and read/write GPRs, the PC, memory, and the breakpoints. This
is a deliberately minimal stand-in for the real RISC-V Debug Module, with the same
shape (abstract register accesses driving the core).

**`rtl/soc_dbg.v`** — `cpu_core_dbg` + RAM/UART/timer/syscon + the debug module,
with the DMI brought out to the top so a transport (a JTAG/UART bridge on
hardware, or a testbench in sim) can drive it. While the DM issues a memory
request it transparently borrows the system bus.

**`sw/gdbstub.py`** — a GDB Remote Serial Protocol server. It implements the
packets gdb actually sends (`?`, `g`/`G`, `p`/`P`, `m`/`M`, `c`, `s`, `Z1`/`z1`,
ctrl-C) and translates each into DMI register accesses. The transport is
pluggable: `SerialDMI` for an on-board bridge, `MockDMI` for the self-test.

## What's verified here

**A full debug session in simulation** (`make debug`) drives the DMI through every
feature against the running `dbg_demo` program (a loop over a global counter):

```
=== HALT ===
halted at pc=0x00000618          <- caught in the loop body
a5 (loop index i) = 80
counter@0x7ac=79  total@0x7a8=3160
=== SINGLE-STEP x6 (PC walks the loop) ===
  step 0 -> pc=0x0000061c        <- PC advances one instruction at a time
  ... 0x620, 0x624, 0x628, 0x618, 0x61c
=== HARDWARE BREAKPOINT @0x618 ===
hit bp: pc=0x00000618  i=82
hit bp: pc=0x00000618  i=83       <- stops again one iteration later
=== WRITE reg + mem, read back ===
x6  <- 0xDEADBEEF, read back 0xdeadbeef
mem[0x300] <- 0xCAFE, read back 0x0000cafe
=== resume to completion ===      <- program runs on and halts normally
```

**The gdb server** (`make debug-selftest`) runs its RSP handlers against a model
of the DM and checks every command:

```
qSupported OK ... ? halts -> S05 OK ... read/write reg OK ... read/write mem OK
g len (33 regs) OK ... single-step advances pc OK ... breakpoint stop pc OK
SELFTEST: PASS
```

So the two hard parts — the hardware that can actually halt/step/inspect, and the
protocol translation gdb expects — are each verified.

## Connecting real gdb (the remaining integration)

The one piece not wired here is the **transport** between `gdbstub.py` and the DMI,
because it depends on where the core runs:

- **On the FPGA:** add a debug-UART bridge (a UART-RX path feeding a small FSM that
  turns the framed `W addr data` / `R addr` protocol in `SerialDMI` into DMI
  accesses). Then on the host:
  ```
  python3 sw/gdbstub.py /dev/ttyUSB1 &
  riscv64-unknown-elf-gdb build/dbg.elf -ex 'target remote :3333'
  (gdb) break main      (gdb) continue      (gdb) info registers      (gdb) step
  ```
  gdb uses the ELF for symbols/disassembly and the hardware breakpoints for stops,
  so it works even though instruction memory isn't read over the data bus.

- **Against the simulator:** a co-simulation bridge (an iverilog VPI module that
  exposes the DMI over a TCP socket) would let gdb debug the *simulated* core. That
  VPI shim is the natural next addition.

## Honest status

- The debug **hardware** and the **gdb protocol server** are implemented and
  verified independently. A live `gdb` session needs the transport bridge above;
  that glue (a UART-RX bridge or a VPI socket) is the remaining work, not new CPU
  capability.
- Breakpoints are **hardware** (PC comparators), so they work in ROM — but there
  are NBP of them (4). Software breakpoints (gdb's default `Z0`) would need
  writable instruction memory; the stub maps both `Z0` and `Z1` onto the hardware
  comparators.
- It's wired into the single-cycle `cpu_core`. The same hooks (`run`-gating, a
  halt FSM, breakpoint comparators, register/PC taps) port to the multi-cycle and
  pipelined cores with more care around their multi-cycle/in-flight state.

## Takeaway

A debugger's power comes from a surprisingly small hardware contract: a way to
freeze the pipeline, peek and poke the register file and memory, and compare the
PC against a few breakpoint registers. Gate every commit with one `run` signal and
you have halt and single-step almost for free; add a handful of comparators and a
register interface and a real gdb can drive the chip.
