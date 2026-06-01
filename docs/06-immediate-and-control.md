# Step 06 — Immediate generator and control unit

So far every block has been a passive resource: storage you read and write.
This step builds the **brains** — the logic that looks at an instruction and
decides what everything else should do. Two pieces:

1. **Immediate generator** — reassembles the scattered immediate bits into a
   clean 32-bit constant.
2. **Control unit** — turns the opcode (plus a couple of function bits) into
   the control signals that steer the datapath.

Both are pure combinational logic. Files:
- `rtl/immgen.v`, `rtl/control.v`
- `tb/immgen_tb.v`, `tb/control_tb.v`

---

## Part A — The immediate generator

### Why immediates are scrambled

A natural question: why doesn't RV32I just put the immediate in one contiguous
field? Because it deliberately keeps `rd`, `rs1`, `rs2`, and the sign bit
(always `instr[31]`) in the *same positions* across all formats. That makes the
register-read and sign-extend hardware identical for every instruction — the
decode is cheaper. The price is that immediates are chopped into pieces, which
we pay for once, here, in the immediate generator.

### The five layouts

| Type | Used by | Immediate assembly (bit sources) |
|------|---------|----------------------------------|
| I | `addi`, `lw`, `jalr`, ... | `instr[31:20]` |
| S | `sw`, `sb`, `sh` | `{instr[31:25], instr[11:7]}` |
| B | branches | `{instr[31], instr[7], instr[30:25], instr[11:8], 0}` |
| U | `lui`, `auipc` | `{instr[31:12], 12'b0}` |
| J | `jal` | `{instr[31], instr[19:12], instr[20], instr[30:21], 0}` |

All but U are **sign-extended** from `instr[31]`. B and J immediates have an
implicit `0` in bit 0 (branch/jump targets are always even — instructions are
2- or 4-byte aligned), which is why those layouts end in `1'b0`.

### The hardware

```verilog
always @(*) begin
    case (imm_type)
        IMM_I: imm = {{20{instr[31]}}, instr[31:20]};
        IMM_S: imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
        IMM_B: imm = {{19{instr[31]}}, instr[31], instr[7],
                      instr[30:25], instr[11:8], 1'b0};
        IMM_U: imm = {instr[31:12], 12'b0};
        IMM_J: imm = {{11{instr[31]}}, instr[31], instr[19:12],
                      instr[20], instr[30:21], 1'b0};
        default: imm = 32'd0;
    endcase
end
```

The whole block is concatenation (`{...}`) and bit-replication (`{N{bit}}`).
Read `{{20{instr[31]}}, instr[31:20]}` as: "twenty copies of the sign bit,
followed by the 12 immediate bits" = a sign-extended 12-bit value. Count the
bits in each line; they all total 32.

### Tested against real instructions

The testbench uses genuine, hand-encoded RV32I words so it's a real check of
both the hardware *and* our understanding of the encoding:

```
ok   instr=fff00093 type=000 -> ffffffff   <- addi x1,x0,-1
ok   instr=00500093 type=000 -> 00000005   <- addi x1,x0,5
ok   instr=abcde0b7 type=011 -> abcde000   <- lui  x1,0xABCDE
ok   instr=00000463 type=010 -> 00000008   <- beq  x0,x0,+8
ok   instr=001000ef type=100 -> 00000800   <- jal  x1,+0x800
ok   instr=fe000fa3 type=001 -> ffffffff   <- store with imm = -1
ALL TESTS PASSED
```

If you want to confirm one by hand, take `addi x1,x0,-1` = `0xFFF00093`: the
top 12 bits are `0xFFF` (= −1 in 12-bit two's complement), and sign-extending
gives `0xFFFFFFFF`. Exactly what the generator produced.

---

## Part B — The control unit

The control unit is a lookup table in disguise. Input: `opcode`, `funct3`, and
`instr[30]` (the one funct7 bit that ever matters in RV32I — it picks `sub`
vs `add` and `sra` vs `srl`). Output: a bundle of control signals.

### The control signals and what they steer

| Signal | Meaning |
|--------|---------|
| `reg_write` | write the result into register `rd` |
| `alu_src_a` | ALU operand A: `0`=rs1, `1`=PC (for `auipc`) |
| `alu_src_b` | ALU operand B: `0`=rs2, `1`=immediate |
| `mem_read` | this instruction is a load |
| `mem_write` | this instruction is a store |
| `branch` | conditional branch (datapath decides taken/not) |
| `jump` | `jal` or `jalr` |
| `jalr` | target comes from `rs1+imm` (vs `PC+imm` for `jal`) |
| `wb_sel` | what value writes back: ALU / memory / PC+4 / immediate |
| `imm_type` | which immediate layout the immgen should build |
| `alu_op` | the 4-bit ALU operation from Step 03 |

`wb_sel` deserves a note — different instruction classes write back different
things: arithmetic writes the ALU result, loads write memory data, `jal`/`jalr`
write the return address `PC+4`, and `lui` writes the immediate directly.

### The structure: defaults then override

```verilog
always @(*) begin
    // 1) Safe defaults: an unknown opcode does nothing (a NOP).
    reg_write=0; alu_src_a=0; alu_src_b=0; mem_read=0; mem_write=0;
    branch=0; jump=0; jalr=0; wb_sel=WB_ALU; imm_type=IMM_I; alu_op=ALU_ADD;

    // 2) Override only what each opcode needs.
    case (opcode)
        OP_R    : begin reg_write=1; alu_op=alu_decode(funct3,funct7b5,0); end
        OP_I    : begin reg_write=1; alu_src_b=1; alu_op=alu_decode(funct3,funct7b5,1); end
        OP_LOAD : begin reg_write=1; alu_src_b=1; mem_read=1; wb_sel=WB_MEM; end
        OP_STORE: begin alu_src_b=1; imm_type=IMM_S; mem_write=1; end
        OP_BR   : begin branch=1; imm_type=IMM_B; alu_op=ALU_SUB; end
        OP_JAL  : begin reg_write=1; jump=1; imm_type=IMM_J; wb_sel=WB_PC4; end
        OP_JALR : begin reg_write=1; jump=1; jalr=1; alu_src_b=1; wb_sel=WB_PC4; end
        OP_LUI  : begin reg_write=1; imm_type=IMM_U; wb_sel=WB_IMM; end
        OP_AUIPC: begin reg_write=1; alu_src_a=1; alu_src_b=1; imm_type=IMM_U; end
        default : ; // illegal -> keep defaults
    endcase
end
```

This "assign safe defaults at the top, then override in the `case`" pattern is
the single most useful idiom for control logic. It guarantees every signal is
always assigned (no inferred latches), and it makes each instruction's entry
read as just *the differences* from a NOP.

### A Verilog `function` for ALU-op decode

Picking the ALU operation from `funct3`/`funct7` is needed for both R-type and
I-type, so it's factored into a `function`:

```verilog
function [3:0] alu_decode;
    input [2:0] f3; input f7b5; input is_imm;
    case (f3)
        3'b000: alu_decode = is_imm ? ALU_ADD : (f7b5 ? ALU_SUB : ALU_ADD);
        3'b001: alu_decode = ALU_SLL;
        3'b010: alu_decode = ALU_SLT;
        3'b011: alu_decode = ALU_SLTU;
        3'b100: alu_decode = ALU_XOR;
        3'b101: alu_decode = f7b5 ? ALU_SRA : ALU_SRL;
        3'b110: alu_decode = ALU_OR;
        3'b111: alu_decode = ALU_AND;
    endcase
endfunction
```

A Verilog `function` is pure combinational logic with one return value (it
can't contain delays or clock edges). The `is_imm` argument captures one real
subtlety: for **R-type**, `funct3==000` with `instr[30]=1` means `sub`; but for
**I-type**, `funct3==000` is always `addi` — there is no "subtract immediate",
and `instr[30]` there is just part of the immediate, not an opcode bit. So
`is_imm` forces ADD in that one case. (For I-type *shifts*, `funct3==101`,
`instr[30]` legitimately selects `srai` vs `srli`, and the function still uses
it.)

### Note on branches

For branches the control unit sets `branch=1` and `alu_op=ALU_SUB`, but the
actual taken/not-taken decision (which depends on `funct3`: `beq`, `bne`,
`blt`, ...) is made in the datapath in Step 07, where a small comparator looks
at `rs1`, `rs2`, and `funct3`. The control unit's job is only to flag "this is
a branch".

### Tested across the instruction set

The testbench drives the opcode/funct combination for one representative of
each instruction class and checks the entire output bundle at once:

```
ok   add     ok   sub     ok   slt     ok   addi
ok   slli    ok   srai    ok   lw      ok   sw
ok   beq     ok   jal     ok   jalr    ok   lui
ok   auipc   ok   illegal
ALL TESTS PASSED
```

The `addi` case specifically passes `funct7b5=1` to confirm it's *ignored*
(still ADD), and `illegal` confirms an unknown opcode produces an all-defaults
NOP with `reg_write=0`.

## Build and run

```bash
iverilog -g2012 -Wall -o build/immgen_tb.vvp  rtl/immgen.v  tb/immgen_tb.v  && vvp build/immgen_tb.vvp
iverilog -g2012 -Wall -o build/control_tb.vvp rtl/control.v tb/control_tb.v && vvp build/control_tb.vvp
```

## Checkpoint

Every component now exists and is independently tested: ALU, register file,
instruction/data memory, immediate generator, control unit. The hard part is
done. What remains is wiring — connecting these blocks so an instruction flows
through them correctly — and then feeding the machine a real program.

## Next

`docs/07-datapath.md` — the single-cycle datapath. We connect all six blocks,
add the PC and its next-PC logic (sequential, branch, and jump targets), the
branch comparator, and the write-back multiplexer, producing a complete CPU
module. Then a testbench runs hand-written instructions through it.
