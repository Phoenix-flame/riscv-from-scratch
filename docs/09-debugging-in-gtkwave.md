# Step 09 — Debugging in GTKWave

You have a working CPU. The last skill to build is reading its waveforms,
because the first time you write a new instruction or program, something *will*
be wrong, and the waveform is where you find out why. This step turns GTKWave
from a wall of wiggles into a diagnostic instrument.

Files:
- `build/sum_tb.gtkw` — a ready-made GTKWave session with the useful signals
  pre-loaded and grouped.

## Launching with a saved view

Every testbench writes a `.vcd`. You can open one raw:

```bash
gtkwave build/sum_tb.vcd
```

…but then you have to add signals every time. Instead, load the saved session
that ships with this step:

```bash
make wave-sum          # == gtkwave build/sum_tb.vcd build/sum_tb.gtkw
```

A `.gtkw` file records which signals are shown, their order, grouping, and
display radix. Once you've arranged a view you like, **File → Write Save File**
captures it so you never rebuild it by hand. The provided one groups signals by
pipeline phase: Fetch, Decode/control, Registers/ALU, Write-back.

## The GTKWave layout

- **SST** (top-left): the signal hierarchy tree — `sum_tb` → `dut` → `u_alu`,
  `u_regfile`, etc. Click a module to list its signals below.
- **Signals** (bottom-left): the signals currently displayed.
- **Waves** (right): the actual waveform traces over time.
- **Time controls** (top): zoom, and the marker readouts.

Essential interactions:
- **Add a signal**: select it in SST, click *Append* (or drag to the Waves
  pane).
- **Change radix**: right-click a trace → *Data Format* → Hex / Decimal /
  Signed Decimal / Binary. Buses default to a format that may not be what you
  want; addresses and data are easiest in hex, counters in decimal.
- **Zoom Fit**: the "zoom-to-fit" toolbar button shows the whole run; *Zoom In*
  around a marker to inspect one cycle.
- **Markers**: left-click drops the primary marker; the time and each signal's
  value at that instant appear next to the names. Drop a second marker to
  measure an interval.

## Recipe: trace one instruction through the datapath

This is the core debugging move. Pick a cycle and read the whole datapath at
that instant.

1. Run `make wave-sum` and Zoom Fit. Find `dut.pc` and `dut.instr` near the
   top; these tell you *which* instruction is executing each cycle.
2. Click to drop a marker on a cycle where `pc = 0x10` (the `add x1,x1,x2`
   in the sum program). At that marker, read across:
   - `opcode = 0110011` (R-type), `funct3 = 000` → an `add`.
   - `rs1_data` and `rs2_data` show the current `sum` and `i`.
   - `alu_result` should equal their sum.
   - `reg_write = 1`, `rd_addr = 1` (x1), `wb_sel = 00` (ALU) →
     `wb_data = alu_result`.
   - `branch = 0`, `jump = 0` → `next_pc = pc + 4 = 0x14`.
3. Advance one cycle (the next rising `clk`). `pc` becomes `0x14`, and
   `dut.u_regfile.regs[1]` (expand the regfile in SST) has taken the new sum.

Watching `pc` step `0x0c → 0x10 → 0x14 → 0x18 → 0x0c` ten times *is* the loop
executing. When you see `pc` jump from `0x18` back to `0x0c`, that's the
`jal loop` taking effect. When the counter finally hits the limit, you'll see
`branch_taken = 1` at the `bge` and `pc` jump to `0x1c` (done).

> **Single-cycle timing reminder:** the combinational signals (`instr`,
> `alu_result`, `wb_data`, `next_pc`) settle to the *current* instruction's
> values during the cycle; the state (`pc`, `regs`, data memory) updates on the
> rising edge that ends it. So at a given `pc`, the `wb_data` you see is what's
> *about to* be written, and it lands in the register right after the next edge.

## Reading values that aren't 0 or 1

Two special signal states matter a lot when debugging:

- **`x` (red trace / "x")** — *unknown*. A signal is `x` when it was never
  driven or is driven by an uninitialized register. If `alu_result` is `x`,
  trace its inputs back: an `x` on `rs1_data` usually means you read a register
  before anything wrote it, or a wire isn't connected.
- **`z` (yellow trace / "z")** — *high-impedance*, i.e. nothing is driving the
  wire. In this design you should essentially never see `z`; if you do, a
  module output likely isn't connected, or two things drive one wire.

`x` propagation is your friend: it spreads from the root cause downstream, so
follow the `x` *upstream* (toward its source) to find the bug.

## Common bug signatures

These are the patterns you'll learn to recognize at a glance:

**Inferred latch (forgot a `default`/`else` in `always @(*)`).** A
combinational signal *holds* its old value across cycles when its inputs change
— it looks "sticky." Icarus also often warns at compile time. Fix: assign the
output on every path (the defaults-at-top idiom from Step 06).

**Used `=` instead of `<=` in a clocked block (or vice-versa).** Sequential
results appear one cycle early or late, or two registers that should update
together don't. If a register seems to "skip ahead," check the assignment
operator.

**Wrong immediate.** `imm` in the waveform doesn't match what you expect for
the instruction. Cross-check against the disassembly (`objdump -d`). A common
cause is the wrong `imm_type` from the control unit — verify `imm_type` matches
the opcode (I/S/B/U/J).

**Mux select stuck.** `alu_b` always equals `rs2_data` even on an `addi` →
`alu_src_b` is wrong. Put the select line (`alu_src_b`, `wb_sel`, ...) next to
the mux output and confirm they track.

**Off-by-one branch/jump target.** `pc` lands one instruction away from where
the label should be. Check `pc_target = pc + imm` and remember B/J immediates
have an implicit `0` LSB (Step 06) — a target that's off by exactly 2× suggests
the immediate's bit-0 handling is wrong.

**`reg_write` asserted on a store/branch.** A register changes during a `sw`
or `beq` that shouldn't write anything. Check the control unit entry — stores
and branches have `reg_write = 0`.

**`x0` not zero.** If `x0` ever reads nonzero, the hard-wiring in the register
file (Step 04) is broken — but you tested that, so suspect a different `rd_addr`.

## Combine waveforms with `$display` tracing

Waveforms show *everything* but make it tedious to scan a long run. A printed
trace (like the per-cycle `$display` in `cpu_tb.v`/`sum_tb.v`) gives a quick
textual log of `pc`/`instr` you can eyeball first, then jump into the waveform
at the exact cycle that looks wrong. Use both: the log to *locate* the bad
cycle, the waveform to *diagnose* it.

A handy pattern for a new instruction is to add a targeted print:

```verilog
always @(posedge clk)
    if (!rst)
        $display("t=%0t pc=%h instr=%h rd=%0d wb=%h",
                 $time, dut.pc, dut.instr, dut.rd_addr, dut.wb_data);
```

## A debugging checklist

When a program misbehaves, in order:

1. **Disassemble** (`objdump -d`) and confirm the machine code is what you
   meant — many "CPU bugs" are actually program bugs.
2. **Scan the `$display` trace** for the first wrong `pc` or value.
3. **Open the waveform at that cycle** and trace the datapath (the recipe
   above): instruction → control signals → operands → ALU → write-back / next-PC.
4. **Follow `x`/wrong values upstream** to the first signal that's wrong; that's
   almost always at or next to the bug.
5. If the block itself is suspect, **re-run its unit testbench** — those
   isolate each block, so a passing unit test points the finger at the *wiring*
   in `cpu.v` instead.

That last point is why we built bottom-up with a testbench per block: when the
whole CPU misbehaves but every unit test still passes, the bug is in how the
pieces connect — a small, well-defined search space.

## You're done

You've built and verified, from scratch:

- an ALU, register file, instruction and data memory, immediate generator, and
  control unit — each unit-tested;
- a single-cycle RV32I datapath wiring them together;
- a toolchain flow that assembles real RISC-V programs and runs them;
- and the skills to read the waveforms and debug what you build next.

### Where to go next

- **More instructions / a bigger program** — the core already supports RV32I;
  try Fibonacci, an array sum with a `lw`/`sw` loop, or `lui`/`auipc` for
  building large constants.
- **A `tohost`-style halt** — have a store to a magic address stop the
  simulation cleanly (so the testbench doesn't need a fixed cycle count).
- **Pipelining** — split the single cycle into IF/ID/EX/MEM/WB stages and add
  hazard handling. This is the natural next project and a large topic on its
  own; the single-cycle core is the reference model you'll check it against.
- **Synthesis** — the RTL (everything in `rtl/`, minus the simulation-only
  `initial` blocks) is largely synthesizable; an FPGA flow is another direction.

Congratulations — you have a real, programmable RISC-V processor that you
understand end to end.
