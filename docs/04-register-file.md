# Step 04 — The register file

The register file holds the 32 general-purpose registers `x0`–`x31`. It's the
CPU's fast scratchpad: almost every instruction reads one or two registers and
writes one back. This is our **first clocked (sequential) block**, so it's
where the ideas from crash-course §4 become concrete.

Files for this step:
- `rtl/regfile.v` — the hardware
- `tb/regfile_tb.v` — the testbench

## What it must do

- **Two read ports.** R-type instructions like `add x3, x1, x2` need both `x1`
  and `x2` in the same cycle, so we provide two independent read outputs.
- **One write port.** At most one register is written per instruction (`rd`).
- **`x0` is hard-wired to zero.** Reads of `x0` always return 0; writes to it
  are silently dropped. This is a RISC-V invariant the hardware must enforce.

## Why reads are combinational but writes are clocked

This is the key design decision, and it's dictated by the single-cycle plan:

- **Reads must be immediate (asynchronous).** Within one clock period the CPU
  reads operands → runs them through the ALU → writes the result back. If a
  read had to wait for a clock edge, none of that could finish in one cycle.
  So the read ports are pure combinational logic — change the address, the
  data appears.

- **Writes happen on the clock edge (synchronous).** The new value for `rd`
  is computed combinationally during the cycle, but it's only *committed* into
  the register at the rising edge that ends the cycle. That edge is the single
  moment the machine's state advances.

A consequence to remember: if an instruction reads and writes the *same*
register in one cycle, the read sees the **old** value, because the write
hasn't taken effect yet. In single-cycle that's exactly the correct behavior.

## The hardware

```verilog
`default_nettype none

module regfile (
    input  wire        clk,
    input  wire        we,
    input  wire [4:0]  rs1_addr, rs2_addr, rd_addr,
    input  wire [31:0] rd_data,
    output wire [31:0] rs1_data, rs2_data
);
    reg [31:0] regs [0:31];        // 32 registers, 32 bits each

    integer i;
    initial for (i = 0; i < 32; i = i + 1) regs[i] = 32'd0;

    // synchronous write, never to x0
    always @(posedge clk)
        if (we && (rd_addr != 5'd0))
            regs[rd_addr] <= rd_data;

    // asynchronous reads, x0 reads as 0
    assign rs1_data = (rs1_addr == 5'd0) ? 32'd0 : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'd0 : regs[rs2_addr];
endmodule

`default_nettype wire
```

### New Verilog in this block

- **A memory array:** `reg [31:0] regs [0:31];` declares 32 elements, each a
  32-bit `reg`. The first `[31:0]` is the *width* of each element; the trailing
  `[0:31]` is the *depth* (how many elements). Index it like `regs[rd_addr]`.

- **`always @(posedge clk)`** — the block runs only on the rising edge of
  `clk`. Everything inside describes flip-flops. This is what gives the design
  *memory*: values persist from one cycle to the next.

- **Non-blocking assignment `<=`** — required in clocked blocks. All `<=`
  right-hand sides are sampled at the edge, then applied together, matching how
  real flip-flops capture inputs simultaneously. (Using `=` here would model an
  unrealistic ordering and cause subtle bugs once many registers update at
  once. See crash-course §4.)

- **The `initial` loop** — runs once at time 0 to zero the array. This is a
  *simulation convenience* so our test programs start from a known state and
  waveforms are clean. It's the one place we tolerate `initial` in RTL; real
  silicon would reset or let software initialize.

### How `x0` is enforced — twice

We guard it on both sides:
- **Write side:** `if (we && rd_addr != 0)` — a write targeting `x0` is
  dropped, so `regs[0]` never changes.
- **Read side:** `(rs1_addr == 0) ? 32'd0 : regs[rs1_addr]` — even if `regs[0]`
  somehow held garbage, a read of address 0 returns a literal zero.

Belt and suspenders. The read-side guard alone is sufficient for correctness,
but enforcing both makes the intent unmistakable and is robust to mistakes.

## The testbench

Driving a clocked block needs a clock and careful timing, so the testbench
introduces two new patterns.

**A free-running clock:**
```verilog
initial clk = 0;
always #5 clk = ~clk;      // flips every 5 ns -> a 10 ns period
```

**Edge-synchronized stimulus.** We change inputs on the *falling* edge so they
are stable and set up before the *rising* edge that captures them:
```verilog
task write_reg;
    input [4:0] addr; input [31:0] data;
    begin
        @(negedge clk);              // change inputs while clk is low
        we = 1; rd_addr = addr; rd_data = data;
        @(posedge clk);              // <- the write is captured here
        @(negedge clk); we = 0;      // drop write enable afterwards
    end
endtask
```

`@(posedge clk)` / `@(negedge clk)` mean "wait until the clock rises/falls".
This is the standard way to align testbench activity with the hardware's clock,
and it avoids races between your stimulus and the edge that samples it.

The test then checks: fresh registers read 0; a written value reads back;
other registers are undisturbed; writing `x0` does nothing; a write with
`we = 0` is ignored; and both read ports work simultaneously.

## Build and run

```bash
cd riscv-cpu-tutorial
iverilog -g2012 -Wall -o build/regfile_tb.vvp rtl/regfile.v tb/regfile_tb.v
vvp build/regfile_tb.vvp
```

Expected output:

```
ok   read x1 -> 00000000        <- fresh register is zero
ok   read x1 -> deadbeef        <- after writing it
ok   read x2 -> 0000002a
ok   read x0 -> 00000000        <- write to x0 had no effect
ok   read x3 -> 00000000        <- write with we=0 ignored
ok   dual read -> deadbeef , 0000002a
--------------------------------------------------
ALL TESTS PASSED
```

(The same harmless "no explicit time unit" warning for `regfile` appears, for
the same reason as the ALU — timing lives in the testbench, not the RTL.)

## Look at it in GTKWave

```bash
gtkwave build/regfile_tb.vcd
```

Add `clk`, `we`, `rd_addr`, `rd_data`, `rs1_addr`, `rs1_data`. This time you'll
see the difference between combinational and clocked behavior directly:
- `rs1_data` changes the instant `rs1_addr` changes (combinational read).
- A new value only appears in a register *at a rising edge* of `clk`, and only
  when `we` is high — watch `rd_data` get latched on the edge.

Expand `dut` → `regs` in the SST tree to watch individual registers fill in as
the test writes them.

## Checkpoint

You now have a tested register file and have met the core sequential-logic
toolkit: memory arrays, `always @(posedge clk)`, non-blocking `<=`, and
clock-aligned testbench stimulus with `@(posedge/negedge clk)`.

## Next

`docs/05-memories.md` — instruction memory and data memory. We'll load a
program from a hex file into instruction memory, and build a byte-addressed
data memory for `lw`/`sw`. After that we have all the storage elements; the
remaining steps wire them together.
