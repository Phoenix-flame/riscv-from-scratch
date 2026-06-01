# Step 02 — Verilog crash course (grounded in real hardware)

This is a refresher, not a full language course. It covers exactly the Verilog
you need to read and write this CPU, using snippets from the ALU we build in
Step 03. The single most important idea first:

> **Verilog describes hardware, not a program.** You are not writing
> instructions that run top-to-bottom. You are describing wires, gates, and
> registers that all exist *simultaneously*. The simulator then computes how
> signals propagate over time.

Keep that in mind and the rest follows.

## 1. Modules and ports

A `module` is a hardware block with a boundary of input/output ports. It is
the unit of design and reuse.

```verilog
module alu (
    input  wire [31:0] a,        // 32-bit input bus
    input  wire [31:0] b,
    input  wire [3:0]  alu_op,   // 4-bit input
    output reg  [31:0] result,   // 32-bit output (driven in an always block)
    output wire        zero      // 1-bit output (driven by assign)
);
    // ... body ...
endmodule
```

- `[31:0]` declares a 32-bit vector, bit 31 down to bit 0. Bit 0 is the LSB.
- Ports have a **direction** (`input`/`output`) and a **type** (`wire`/`reg`).

## 2. `wire` vs `reg` — the perennial confusion

This trips up everyone, so be precise:

- **`wire`**: a physical connection with no memory. It must be *continuously
  driven* by something else (an `assign` or a module output). Think of it as a
  literal piece of wire.
- **`reg`**: a variable that *holds* its value until reassigned, inside a
  `always`/`initial` block. Despite the name, a `reg` is **not** necessarily a
  hardware register/flip-flop! Whether it becomes a flip-flop or just
  combinational logic depends on *how* you assign it (see §4).

Rule of thumb:
- If a signal is assigned inside an `always` block → declare it `reg`.
- If it's driven by a continuous `assign` or is a module's input → `wire`.

In the ALU, `result` is a `reg` because we set it inside `always @(*)`, while
`zero` is a `wire` because we drive it with a continuous `assign`.

## 3. Continuous assignment (`assign`)

```verilog
assign zero = (result == 32'd0);
```

This is permanent combinational logic: *whenever* `result` changes, `zero`
recomputes. There is no "when" — it's always true, like a law of physics on
that wire. Only `wire`s can be driven by `assign`.

## 4. `always` blocks: combinational vs sequential

The `always` block is where most logic lives. The sensitivity list (the part
after `@`) decides what kind of hardware you get.

### Combinational logic — `always @(*)`

```verilog
always @(*) begin          // "*" = re-evaluate when ANY input changes
    case (alu_op)
        ALU_ADD : result = a + b;
        ALU_SUB : result = a - b;
        // ...
        default : result = 32'd0;   // ALWAYS provide a default
    endcase
end
```

`@(*)` means "recompute this block whenever any signal it reads changes". This
describes pure combinational logic (gates). Two rules to avoid bugs:

1. Use **blocking assignment `=`** in combinational blocks.
2. Assign the output on **every** path (hence the `default`). If you forget a
   path, the tool infers a *latch* to "remember" the old value — almost never
   what you want, and a classic source of bugs. The `default` clause guarantees
   `result` always gets a value.

### Sequential logic — `always @(posedge clk)`

This is what creates actual flip-flops (memory). You'll meet it in Step 04
(the register file). Preview:

```verilog
always @(posedge clk) begin    // act only on the rising clock edge
    if (we) regs[rd] <= wdata; // <- non-blocking assignment
end
```

Here `<=` is a **non-blocking assignment**. In sequential logic you must use
`<=`, not `=`. The reason: non-blocking assignments all sample their
right-hand sides *first*, then update together at the clock edge — which
matches how real flip-flops behave (they all capture their inputs
simultaneously).

### The one rule that prevents most beginner bugs

- Combinational (`always @(*)`): use `=`
- Sequential (`always @(posedge clk)`): use `<=`

Memorize that and you avoid a whole category of subtle races.

## 5. Number literals

Format: `<width>'<base><value>`.

```verilog
32'd12        // 32 bits, decimal 12
4'b0001       // 4 bits, binary
32'hFF00FF00  // 32 bits, hex
-32'sd7       // 32-bit signed decimal -7
1'b1          // a single bit, value 1
```

`'b` binary, `'d` decimal, `'h` hex, `'o` octal. The `s` (as in `'sd`) marks
the literal as signed. Underscores are allowed for readability: `32'hDEAD_BEEF`.

## 6. Operators you'll use constantly

- Arithmetic: `+ - * `
- Bitwise: `& | ^ ~`
- Logical: `&& || !`
- Shifts: `<<` (left), `>>` (logical right), `>>>` (arithmetic right)
- Comparison: `== != < > <= >=`
- Concatenation: `{a, b}` joins buses; `{4{1'b1}}` replicates → `4'b1111`
- Ternary: `cond ? x : y`
- Part-select: `b[4:0]` takes the low 5 bits of `b`

### Signed vs unsigned: `$signed`

By default Verilog treats vectors as unsigned. To get signed behavior (for
`slt` and arithmetic shift right) wrap the operand:

```verilog
result = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;   // signed compare
result = $signed(a) >>> shamt;                          // arithmetic shift
```

This is exactly why RV32I distinguishes `slt` from `sltu`.

## 7. Parameters and `localparam`

Named constants. `localparam` cannot be overridden from outside — use it for
fixed encodings like our opcodes:

```verilog
localparam ALU_ADD = 4'b0000;
localparam ALU_SUB = 4'b0001;
```

This keeps the `case` readable and means the same names appear in the
testbench, so a typo can't silently disagree.

## 8. The simulation / synthesis split

Some Verilog describes hardware ("synthesizable"); some only controls the
simulator. You must keep them separate:

| Synthesizable (in `rtl/`) | Simulation-only (in `tb/`) |
|---------------------------|-----------------------------|
| `module`, ports, `assign` | `initial` blocks |
| `always @(*)` / `@(posedge)` | `$display`, `$finish` |
| `wire`, `reg`, `case`, `if` | `$dumpfile`, `$dumpvars` |
| arithmetic, logic | `#delay` timing, `task` |

Anything starting with `$` is a *system task* — it talks to the simulator, not
to hardware. Delays like `#5` mean "advance simulated time"; they're for
testbenches only.

## 9. Anatomy of a testbench

A testbench has no ports. It *instantiates* the design under test (DUT),
drives its inputs from `reg`s, reads its outputs through `wire`s, and checks
them. From `tb/alu_tb.v`:

```verilog
`timescale 1ns/1ps          // time unit / precision for # delays
module alu_tb;
    reg  [31:0] a, b;        // we drive these
    reg  [3:0]  alu_op;
    wire [31:0] result;      // we observe these
    wire        zero;

    alu dut (                // instantiate DUT, connect by .port(signal)
        .a(a), .b(b), .alu_op(alu_op),
        .result(result), .zero(zero)
    );

    initial begin            // runs once at time 0
        $dumpfile("build/alu_tb.vcd");  // where to write the waveform
        $dumpvars(0, alu_tb);           // dump everything in this module
        a = 5; b = 7; alu_op = 4'b0000;
        #1;                              // wait 1 ns for logic to settle
        if (result !== 32'd12) $display("FAIL"); else $display("ok");
        $finish;                         // end the simulation
    end
endmodule
```

Notes:
- `initial` runs once, at the start — perfect for a test script.
- Instantiation `alu dut (...)` connects ports **by name** (`.port(signal)`),
  which is safer than by position.
- `!==` and `===` are 4-state comparisons that also catch `x` (unknown) and
  `z` (high-impedance) values — use them in checks instead of `!=`/`==` so an
  uninitialized signal can't sneak past as "equal".
- `$dumpfile`/`$dumpvars` are what make GTKWave possible.

## 10. Things that bite beginners

- **Inferred latches**: forgetting a branch in a combinational `always`. Fix:
  always have a `default`/`else`, or pre-assign the output at the top of the
  block.
- **Mixing `=` and `<=`** in the same block. Don't. Pick by block type (§4).
- **Wide vs narrow assignment**: assigning a 32-bit value to a 4-bit reg
  silently truncates. `-Wall` warns about width mismatches — heed it.
- **`reg` ≠ register**: it only becomes a flip-flop in an `@(posedge clk)`
  block. In `@(*)` it's just combinational.

That's enough Verilog to build the whole CPU. You'll reinforce each idea as we
use it. On to the first real hardware.

## Next

`docs/03-alu.md` — build and test the ALU.
