# Step 03 — The ALU

The Arithmetic Logic Unit is the CPU's calculator. Give it two 32-bit numbers
and an operation code; it returns a 32-bit result. It's pure combinational
logic — no clock, no memory — which makes it the perfect first block.

Files for this step:
- `rtl/alu.v` — the hardware
- `tb/alu_tb.v` — the self-checking testbench

## What operations does RV32I need?

Looking ahead at the ISA, the integer instructions reduce to ten distinct ALU
operations. We assign each a 4-bit code (these encodings are *our* choice; the
control unit in Step 06 will translate real instructions into them):

| Code | Name | Operation | Used by |
|------|------|-----------|---------|
| `0000` | ADD  | `a + b` | `add`, `addi`, address calc for `lw`/`sw`, branches |
| `0001` | SUB  | `a - b` | `sub`, branch comparisons |
| `0010` | AND  | `a & b` | `and`, `andi` |
| `0011` | OR   | `a \| b` | `or`, `ori` |
| `0100` | XOR  | `a ^ b` | `xor`, `xori` |
| `0101` | SLL  | `a << b[4:0]` | `sll`, `slli` |
| `0110` | SRL  | `a >> b[4:0]` (logical) | `srl`, `srli` |
| `0111` | SRA  | `a >>> b[4:0]` (arithmetic) | `sra`, `srai` |
| `1000` | SLT  | signed `a < b` ? 1 : 0 | `slt`, `slti` |
| `1001` | SLTU | unsigned `a < b` ? 1 : 0 | `sltu`, `sltiu` |

## The design

The whole ALU is one combinational `always @(*)` driving `result`, plus a
continuous `assign` for the `zero` flag.

```verilog
`default_nettype none

module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [3:0]  alu_op,
    output reg  [31:0] result,
    output wire        zero
);
    localparam ALU_ADD=4'b0000, ALU_SUB=4'b0001, ALU_AND=4'b0010,
               ALU_OR =4'b0011, ALU_XOR=4'b0100, ALU_SLL=4'b0101,
               ALU_SRL=4'b0110, ALU_SRA=4'b0111, ALU_SLT=4'b1000,
               ALU_SLTU=4'b1001;

    wire [4:0] shamt = b[4:0];   // RV32I shifts use only low 5 bits

    always @(*) begin
        case (alu_op)
            ALU_ADD : result = a + b;
            ALU_SUB : result = a - b;
            ALU_AND : result = a & b;
            ALU_OR  : result = a | b;
            ALU_XOR : result = a ^ b;
            ALU_SLL : result = a << shamt;
            ALU_SRL : result = a >> shamt;
            ALU_SRA : result = $signed(a) >>> shamt;
            ALU_SLT : result = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
            ALU_SLTU: result = (a < b) ? 32'd1 : 32'd0;
            default : result = 32'd0;
        endcase
    end

    assign zero = (result == 32'd0);
endmodule

`default_nettype wire
```

### Design notes worth understanding

- **`` `default_nettype none ``**: by default, Verilog auto-creates a 1-bit
  wire for any undeclared name — so a typo in a signal name becomes a silent
  1-bit wire instead of an error. Setting `none` at the top of a file disables
  that, turning typos into compile errors. We restore the default (`wire`) at
  the bottom so other files aren't affected. This is a cheap, powerful safety
  net; use it in every RTL file.

- **`shamt = b[4:0]`**: a 32-bit shift by more than 31 is meaningless, so
  RV32I defines shift amounts as only the low 5 bits of the operand. We slice
  them out explicitly so the intent is clear.

- **`$signed(a) >>> shamt`**: `>>>` is the arithmetic right shift, but it only
  sign-extends if its left operand is signed. `a` is declared unsigned, so we
  cast with `$signed`. Compare in the test: `0x80000000 >>> 4` gives
  `0xF8000000` (sign bit copied), whereas logical `>>` gives `0x08000000`.

- **`zero` flag**: branches like `beq` need to know if `a - b == 0`. Rather
  than recompute, we expose whether the *current* result is zero. The datapath
  will feed `SUB` into the ALU and read `zero` to decide a branch.

- **`default` clause**: guarantees `result` is assigned on every path, so the
  synthesizer never infers an unwanted latch (see crash-course §10).

## The testbench

The testbench applies known inputs and checks known outputs. The heart of it
is a reusable `task`:

```verilog
task check;
    input [3:0]  op;
    input [31:0] ia, ib, expected;
    begin
        a = ia; b = ib; alu_op = op;
        #1;                            // let combinational logic settle
        if (result !== expected) begin
            $display("FAIL op=%b a=%h b=%h -> got %h, expected %h",
                     op, ia, ib, result, expected);
            errors = errors + 1;
        end else
            $display("ok   op=%b a=%h b=%h -> %h", op, ia, ib, result);
    end
endtask
```

Then a list of cases exercising each operation, including the tricky ones:
signed vs unsigned compare, arithmetic vs logical shift, subtraction wrap-around,
and the zero flag. An `errors` counter makes the final verdict unambiguous.

## Build and run

```bash
cd riscv-cpu-tutorial
iverilog -g2012 -Wall -o build/alu_tb.vvp rtl/alu.v tb/alu_tb.v
vvp build/alu_tb.vvp
```

Expected output (abbreviated):

```
ok   op=0000 a=00000005 b=00000007 -> 0000000c
ok   op=0001 a=00000003 b=0000000a -> fffffff9
ok   op=0111 a=80000000 b=00000004 -> f8000000   <- arithmetic shift keeps sign
ok   op=1000 a=fffffffb b=00000003 -> 00000001   <- -5 < 3 (signed)
ok   op=1001 a=ffffffff b=00000001 -> 00000000   <- 0xFFFFFFFF !< 1 (unsigned)
--------------------------------------------------
ALL TESTS PASSED
```

> If you see a warning about "no explicit time unit" for module `alu`, it's
> harmless — the RTL deliberately has no `` `timescale `` (timing belongs in
> testbenches). You can silence it by adding `` `timescale 1ns/1ps `` at the
> top of `alu.v`, but leaving RTL timing-free is the cleaner convention.

## Look at it in GTKWave

```bash
gtkwave build/alu_tb.vcd
```

In the GTKWave window:
1. In the top-left **SST** pane, click `alu_tb` → `dut`.
2. Select signals `a`, `b`, `alu_op`, `result`, `zero` and click **Append**
   (or drag them into the Signals list).
3. Right-click a bus → **Data Format → Hexadecimal** to read values as hex.
4. Use **Zoom Fit** (the magnifier-with-square icon) to see all 13 test steps.

You'll see `result` change instantly with each new `alu_op`/`a`/`b` — there's
no clock, confirming this is combinational. Each 1 ns `#1` in the testbench is
one visible step on the time axis.

## Checkpoint

You now have:
- A working, tested ALU.
- A feel for combinational `always @(*)`, `case`, signed operations, and
  self-checking testbenches.
- The full compile → run → view loop.

## Next

`docs/04-register-file.md` — the 32-entry register file. This is our first
*sequential* (clocked) block, where you'll meet `always @(posedge clk)`,
non-blocking assignment `<=`, and the hard-wired-zero `x0` trick.
