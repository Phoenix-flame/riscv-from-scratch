# Step 16 — Multiply and divide (the RV32M extension)

Base RV32I has no multiply or divide — `a * b` in C compiles to a call into a
libgcc software routine. The **M extension** adds hardware multiply/divide as
eight R-type instructions. This step adds them to the ALU.

Changed files: `rtl/alu.v`, `rtl/control.v`, and the `alu_op` width in
`rtl/cpu.v` / `rtl/cpu_core.v`.

## The eight instructions

All are R-type (opcode `0110011`, same as `add`) but with **`funct7 = 0000001`**,
which is how the decoder tells them apart from the base ops:

| funct3 | name | result |
|--------|------|--------|
| 000 | `mul`    | low 32 bits of the product |
| 001 | `mulh`   | high 32 bits, signed × signed |
| 010 | `mulhsu` | high 32 bits, signed × unsigned |
| 011 | `mulhu`  | high 32 bits, unsigned × unsigned |
| 100 | `div`    | signed quotient |
| 101 | `divu`   | unsigned quotient |
| 110 | `rem`    | signed remainder |
| 111 | `remu`   | unsigned remainder |

`mul` gives the low word; the three `mulh*` variants give the high word (for a
full 64-bit product you issue `mulh`/`mulhu` then `mul`). The signed/unsigned
split matters for the high word, so there are three multiply-high variants.

## Widening `alu_op`

We had 10 ALU ops in 4 bits; 8 more pushes us to 18, so `alu_op` grows to **5
bits** everywhere (ALU, control, and the CPU wiring). The new codes (10–17) are
the M ops.

## The ALU implementation

Multiply uses 64-bit products with the operands extended according to
signedness:

```verilog
wire signed [63:0] a_s = $signed({{32{a[31]}}, a});  // sign-extend
wire        [63:0] a_u = {32'b0, a};                 // zero-extend
wire signed [63:0] p_ss = a_s * b_s;   // for mulh
wire        [63:0] p_uu = a_u * b_u;   // for mulhu
wire signed [63:0] p_su = a_s * $signed(b_u);        // for mulhsu
// mul     -> p_ss[31:0]   (low word is the same regardless of sign)
// mulh    -> p_ss[63:32], etc.
```

Divide follows the RV32M spec, including its defined results for the two corner
cases (so software gets deterministic behavior instead of a fault):

```verilog
// divide by zero:     div -> -1,  rem -> dividend
// signed overflow (INT_MIN / -1):  div -> INT_MIN,  rem -> 0
ALU_DIV : result = div0 ? 32'hFFFFFFFF : ovf ? 32'h80000000 : q_s;
ALU_REM : result = div0 ? a            : ovf ? 32'd0        : r_s;
```

### A Verilog signedness gotcha worth remembering

The signed quotient/remainder are computed in their **own signed wires**:

```verilog
wire signed [31:0] q_s = sa / sb;   // sa, sb are $signed(a/b)
```

If you instead wrote `div0 ? 32'hFFFFFFFF : (sa / sb)` directly, the unsigned
literal `32'hFFFFFFFF` would make the *entire* conditional expression unsigned,
and Verilog would silently compute `sa / sb` as an **unsigned** division — the
wrong answer for negative numbers. (This bug actually showed up while building
this step: `-20 / 6` came out as a huge positive number.) Computing the signed
result in a dedicated signed wire first avoids the trap.

## Control-unit change

The control unit now takes the full 7-bit `funct7` (it used to take just bit 5,
which distinguishes `add`/`sub` and `srl`/`sra`). For an R-type it checks
`funct7 == 0000001` to pick the multiply/divide decode:

```verilog
wire is_m = (funct7 == 7'b0000001);
...
OP_R: alu_op = is_m ? alu_muldiv(funct3) : alu_base(funct3, funct7[5], 1'b0);
```

## Verify it on the CPU

The ALU testbench gains M-extension cases (including the divide-by-zero and
overflow corners). To prove it through the whole CPU, `sw/muldiv_demo.c` is
compiled with **`-march=rv32im`**, so GCC emits real `mul`/`div`/`rem`
instructions instead of libgcc calls:

```bash
make muldiv
```

```
6!         = 720
-20 * 6    = -120
-20 / 6    = -3
-20 % 6    = -2
0xffffffff * 0xffffffff hi = 0xfffffffe
6! stored in RAM = 720 (PASS)
```

That `6! = 720` came from a loop of hardware `mul` instructions, and the signed
`-20 / 6 = -3` / `-20 % 6 = -2` confirm signed divide/remainder and truncation
toward zero.

## A note on hardware cost

These are written combinationally for clarity. A combinational multiplier maps
to FPGA DSP blocks and is fine; a **combinational divider is large and slow** —
real cores use a multi-cycle (iterative) divider that takes ~32 cycles and
stalls the pipeline while it runs. Implementing that is a good follow-on once
you've done the pipeline (next step), since it reuses the same stall machinery.

## Next

`docs/17-pipelining.md` — turn the single-cycle datapath into a 5-stage
pipeline with forwarding and hazard handling.
