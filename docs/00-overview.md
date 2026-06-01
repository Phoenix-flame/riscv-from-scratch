# Step 00 — Overview: the plan and the architecture

Before writing any hardware, let's agree on *what* we are building and *why*
the pieces fit together the way they do. Read this once; you'll come back to
the block diagram many times.

## What is RISC-V?

RISC-V is an open instruction set architecture (ISA). An ISA is the contract
between software and hardware: it defines the registers, the instructions,
and exactly what each instruction does to the machine's state. Because it's
open and clean, it's the ideal teaching ISA.

We target the smallest useful subset: **RV32I**, the 32-bit base integer
instruction set. "32" means registers and addresses are 32 bits wide. "I"
means integer-only (no multiply, no floating point — those are optional
extensions we skip).

## The programmer-visible state

A RISC-V core is, from software's point of view, just three things:

1. **32 general-purpose registers**, `x0`–`x31`, each 32 bits.
   - `x0` is special: it is hard-wired to zero. Writes to it are ignored.
2. **A program counter (PC)** — the 32-bit address of the current instruction.
3. **Memory** — a flat array of bytes holding instructions and data.

Everything our CPU does is: read an instruction at PC, change some registers
and/or memory, advance the PC. Repeat forever.

## Instruction formats

Every RV32I instruction is exactly 32 bits. There are six formats. They share
fields in fixed positions so the hardware can decode them cheaply.

```
       31        25 24   20 19   15 14 12 11        7 6      0
R-type [ funct7    ][ rs2 ][ rs1 ][f3 ][   rd      ][ opcode ]   add, sub, and...
I-type [   imm[11:0]      ][ rs1 ][f3 ][   rd      ][ opcode ]   addi, lw, jalr...
S-type [imm[11:5] ][ rs2 ][ rs1 ][f3 ][ imm[4:0]  ][ opcode ]   sw...
B-type [imm[12|10:5]][rs2][ rs1 ][f3 ][imm[4:1|11]][ opcode ]   beq, bne...
U-type [        imm[31:12]              ][   rd    ][ opcode ]   lui, auipc
J-type [    imm[20|10:1|11|19:12]       ][   rd    ][ opcode ]   jal
```

Key fields:
- `opcode` (7 bits): the broad instruction class.
- `rd` (5 bits): destination register number.
- `rs1`, `rs2` (5 bits each): source register numbers.
- `funct3` / `funct7`: pick the exact operation within a class.
- `imm`: an immediate constant, scattered across the word in a way that keeps
  the register fields in the same place across formats. We will reassemble it.

You don't have to memorize this. We'll handle each field as we reach it.

## The single-cycle design

There are many ways to organize a CPU. We use the simplest one that works:
**single-cycle**. Every instruction completes in exactly one clock cycle. The
whole datapath is combinational logic between two state elements (the register
file and PC), which update on the clock edge.

It is not fast or realistic — a real chip pipelines this into stages — but it
is the clearest possible mapping from "what an instruction does" to "what the
wires do". Once it works, pipelining is an optimization you can layer on.

## Block diagram

Here is the whole machine we are going to build, drawn as the flow of one
instruction:

```
        +-----+        +--------------------------------------------+
        | PC  |---+---->| Instruction Memory | -> 32-bit instruction |
        +-----+   |     +--------------------------------------------+
          ^       |                 |
          |       |                 v
          |       |          +--------------+      decode fields
       +-----+    |          | Control Unit |  rs1, rs2, rd, imm, funct
       | +4  |    |          +--------------+
       +-----+    |             |   |   |
          ^       |             v   v   v
   (branch/jump   |        +-------------------+
    target adder) |        |  Register File    | reads rs1, rs2
          |       |        |  (x0..x31)        | writes rd
          +-------+        +-------------------+
                              |        |
                  operand A   v        v  operand B (reg or immediate)
                          +-----------------+
                          |      ALU        | <- Step 03 (done)
                          +-----------------+
                              |   |
                       result |   | zero  (used for branches)
                              v   v
                          +-----------------+
                          |  Data Memory    | (for lw / sw)
                          +-----------------+
                              |
                              v  write-back value
                          (back to Register File rd)
```

We build it **bottom-up**: the small combinational blocks first (ALU,
register file, memories), each fully tested in isolation, then we wire them
together into the datapath, then we feed it a real program.

## Why bottom-up + testbenches?

Hardware bugs are miserable to find once everything is connected. If each
block is proven correct on its own, then when the assembled CPU misbehaves,
the bug is almost always in the *wiring*, not the blocks — which is a far
smaller search space. Every step here ships with a self-checking testbench
that prints `ALL TESTS PASSED` or tells you exactly what failed.

## Next

Go to `docs/01-environment-setup.md` to install and verify the tools.
