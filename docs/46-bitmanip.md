# Step 46 — Bit manipulation: Zba, Zbb, Zbc, Zbs

The bit-manipulation extensions add the instructions that compilers kept
building from three or four base instructions: shift-and-add for array
indexing, count leading zeros, rotate, min/max, byte reverse, single-bit set
and clear. RVA22 makes Zba/Zbb/Zbs mandatory, and GCC uses them whenever
`-march` allows. They cost little: every one is a single-cycle combinational
function of two registers. That makes them the cheapest real ISA extension in
this project.

| group | instructions | what for |
|---|---|---|
| **Zba** | `sh1add sh2add sh3add` | `base + (i << k)`: array indexing in one instruction |
| **Zbb** | `andn orn xnor` | logic with an inverted operand |
| | `clz ctz cpop` | count leading/trailing zeros, population count |
| | `min max minu maxu` | branch-free min/max |
| | `sext.b sext.h zext.h` | sign/zero extension (base RV32I needs two shifts) |
| | `rol ror rori` | rotates |
| | `orc.b rev8` | byte-wise OR-combine (`strlen`), byte reverse (endianness) |
| **Zbc** | `clmul clmulh clmulr` | carry-less multiply: CRC, GCM, polynomial arithmetic |
| **Zbs** | `bclr bset binv bext` (+ `i` forms) | single-bit clear / set / invert / extract |

All four are in `cpu_pipe_u`, the unified pipeline, and each is a parameter
(`ZBA`, `ZBB`, `ZBC`, `ZBS`, default 1) and a menuconfig option.

## The unit

`rtl/zb_unit.v` is one combinational module: opcode, funct3, funct7 and the
`rs2` field in; `hit` and the 32-bit result out. It sits in EX beside the ALU,
fed the same operands the ALU gets: `rs1` after forwarding, and `rs2` or the
immediate. When the instruction in EX is a Zb instruction, its result replaces
the ALU's in `ex_result`. Nothing else in the pipeline changes. Forwarding,
hazards and writeback treat a Zb result exactly like an `add`. That works
because each of these is a single-cycle combinational function of two
registers.

The only part of any size is Zbc's carry-less product. A 32 × 32 → 64-bit
`clmul` is an AND-XOR array, 1,024 ANDs and about as many XORs, which comes
out as roughly 500 LUTs. The DSP48 multipliers cannot help, because they carry. Zbc
is therefore the one group that menuconfig leaves **off** by default: CRC and
AES-GCM code wants it, and most programs do not. `clz`/`ctz`/`cpop` are
priority encoders and an adder tree, and the rotates are a second barrel
shifter.

## Strict decode: an absent extension traps

The Zb instructions reuse the OP and OP-IMM opcodes. Only `funct7` (or the top
bits of the immediate) tells `andn` (funct7 `0100000`, funct3 `111`) apart from
`and` (funct7 `0000000`). The original decoder looked at funct3 alone, so with
no Zb hardware `andn` would have quietly executed as `and`. That is worse than
a trap: the program keeps running with wrong results.

So ID now checks the full encoding. An OP instruction is legal if its funct7
is a base pattern, or `0000001` with M configured, or if it is a Zb encoding
that is configured. A second, operand-less `zb_unit` instance in ID answers the
last question. The same applies to OP-IMM's shift forms. Anything else is an
illegal instruction (`mcause` = 2):

```verilog
wire base_r = (funct7 == 7'b0000000) |
              (funct7 == 7'b0100000 && (funct3_id == 3'b000 || funct3_id == 3'b101)) |
              (funct7 == 7'b0000001 && M_EXT != 0);
wire enc_ok = (opcode == 7'b0110011) ? (base_r | id_zb) :
              (opcode == 7'b0010011) ? (base_i | id_zb) : 1'b1;
```

## Verification

- **The official tests.** riscv-tests has `rv32uzba` (3), `rv32uzbb` (18),
  `rv32uzbc` (3) and `rv32uzbs` (8). `tools/rvtests` now builds the pipeline
  cores with `-march=rv32ima_zicsr_zifencei_zba_zbb_zbc_zbs` and runs them
  too. All four pipeline configurations pass **90/90** (they were 58/58):
  `pipe_u`, `pipe_u_vm` (the test body in U-mode under Sv32), `pipe_c` (I/D
  caches over slow memory) and `pipe_c_vm`. Every other core in the matrix is
  unchanged.
- **The OpenZynq self-test** (`sw/oz/selftest.c`) has one check per configured
  group: sh2add/sh3add; clz/ctz/cpop/rev8/andn/max/rori; clmul/clmulh;
  bset/bexti/binvi. On a configuration without Zbb, it executes `andn` as a
  raw `.word` and expects an illegal-instruction trap. `make rvgen-all` passes
  on every preset.

## Menuconfig

`Core → ISA extensions → Bit manipulation (Zb*)`, pipeline only:

| option | default | adds to `-march` |
|---|---|---|
| `CONFIG_ISA_ZBA` | y | `_zba` |
| `CONFIG_ISA_ZBB` | y | `_zbb` |
| `CONFIG_ISA_ZBC` | **n** | `_zbc` |
| `CONFIG_ISA_ZBS` | y | `_zbs` |

rvgen passes them to `oz_rv_soc` (and on to `cpu_pipe_u`) and to the firmware
build's `-march`, and records them in the `FEATURES` register (bits 16–19).
`oz_full` and `oz_full_ps` enable all four, `oz_vec` all but Zbc, and
`oz_tiny` (RV32I) none.

## Cost

`cpu_pipe_u` alone, `synth_xilinx -arch xc7`, Yosys 0.68 (other parameters at
their defaults, V off). LUTs are logic LUTs (LUT1–LUT6); the register file's
48 LUT-RAM LUTs are the same in every row:

| configuration | LUTs | Δ | CARRY4 |
|---|---:|---:|---:|
| no Zb | 8,903 | | 928 |
| Zbc only | 9,435 | +532 | 928 |
| Zba + Zbb + Zbs | 9,787 | +884 | 963 |
| all four | 10,450 | +1,547 | 963 |

There are no extra flip-flops and no extra pipeline stage, and the timing path
is no longer than the ALU's: `clz` and `cpop` are shallow next to the
combinational divider that already sets the critical path.

## Files

| file | |
|---|---|
| `rtl/zb_unit.v` | the unit (new) |
| `rtl/cpu_pipe_u.v` | `ZBA..ZBS` parameters, strict OP/OP-IMM decode, EX result mux |
| `tools/rvtests` | `-march` with Zb, the four `rv32uzb*` suites on the pipeline cores |
| `Kconfig`, `tools/rvgen/rvgen.py`, `rtl/oz/oz_rv_soc.v` | the options, `-march`, parameters, `FEATURES` |
| `sw/oz/selftest.c` | Zb checks, Zbb-absent check |
