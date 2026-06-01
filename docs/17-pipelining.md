# Step 17 — Pipelining: a 5-stage RV32IM core

The single-cycle core does everything for one instruction in one long clock
period: fetch, decode, read registers, compute, access memory, write back. That
period is set by the *slowest* instruction's full path, which wastes most of the
hardware most of the time. **Pipelining** splits the work into stages so several
instructions are in flight at once — one being fetched while another executes
while another writes back — letting the clock run much faster.

This step builds a classic **5-stage pipeline** in `rtl/cpu_pipe.v` and verifies
it computes exactly the same results as the single-cycle core.

## The five stages

| Stage | Does | Hardware used |
|-------|------|---------------|
| **IF** | fetch the instruction at PC | imem |
| **ID** | decode, read registers, build immediate | control, regfile, immgen |
| **EX** | ALU op; resolve branches/jumps | alu |
| **MEM** | load/store data memory | dmem |
| **WB** | write the result to a register | regfile (write port) |

Between each pair of stages sits a **pipeline register** (`ifid_*`, `idex_*`,
`exmem_*`, `memwb_*`) that latches everything the later stages need. Each clock
edge, every instruction advances one stage. In steady state, five instructions
are in flight and the CPU retires one per cycle — but at a clock set by the
*slowest single stage*, not the whole datapath.

## The catch: hazards

Overlapping instructions create three problems a single-cycle core never had.

### 1. Data hazards → forwarding

```asm
add x3, x1, x2     # x3 produced in EX, written in WB (3 stages later)
sub x5, x3, x4     # needs x3 NOW, in its own EX -- but WB hasn't happened
```

Waiting for WB would stall constantly. Instead we **forward**: route a result
straight from where it's already computed (the EX/MEM or MEM/WB pipeline
register) back to the EX inputs of the waiting instruction.

```verilog
// pick the most recent producer of each source register
if      (exmem_reg_write && exmem_rd==src && src!=0) fwd = EXMEM; // 1 ahead
else if (wb_reg_write    && wb_rd==src    && src!=0) fwd = MEMWB; // 2 ahead
else                                                 fwd = REGFILE;
```

A fourth case — an instruction in WB feeding one in ID *this same cycle* —
is handled by a write/read bypass on the register file read. Together these
cover every distance, so most dependent instructions never stall at all.

### 2. Load-use hazard → one-cycle stall

Forwarding can't beat physics in one spot: a load's data isn't available until
the *end* of MEM, one stage too late for an instruction right behind it that
needs it in EX.

```asm
lw  x5, 0(x1)
add x6, x5, x2     # x5 not ready in time -> must wait one cycle
```

So when a load in EX feeds the instruction in ID, we **stall one cycle**: freeze
the PC and IF/ID, and inject a bubble into ID/EX. After that single cycle the
load is in MEM/WB and ordinary forwarding delivers the value.

```verilog
assign load_use = idex_mem_read && idex_rd!=0 &&
                  (idex_rd==rs1_id || idex_rd==rs2_id);
```

### 3. Control hazards → branch flush

A branch isn't resolved until **EX**, but by then the two instructions behind it
have already been fetched. We **predict not-taken**: keep fetching sequentially,
and if the branch *is* taken (or it's a jump), **flush** those two wrongly-fetched
instructions (turn them into bubbles) and redirect the PC.

```verilog
assign ex_taken  = idex_jump | (idex_branch & branch_cond);
assign ex_target = idex_jalr ? jalr_target : (idex_pc + idex_imm);
// on ex_taken: PC <= ex_target; IF/ID -> NOP; ID/EX -> bubble
```

A taken branch therefore costs 2 cycles; a not-taken one costs nothing. (Real
cores add branch *prediction* to avoid even the taken penalty — a natural
extension.)

## A bubble is just zeroed control

Stalls and flushes both work by inserting a **bubble**: a pipeline-register
entry with all the control signals cleared (`reg_write=0`, `mem_write=0`,
`branch=0`, ...). A bubble flows down the pipe doing nothing and committing
nothing — exactly what we want for a squashed slot.

## Multiply/divide in the pipeline

Because the RV32M ops from Step 16 are *combinational*, they finish within the
EX stage like any ALU op — no special handling needed. (A realistic multi-cycle
divider would assert a stall until it's done, reusing the same stall machinery
as the load-use case.)

## Verification: same results, different microarchitecture

The proof a pipeline is correct is that it's *architecturally invisible* — it
must produce the identical register/memory state as the simple core, just
faster. So `tb/pipe_tb.v` runs the exact program from Step 07 and checks every
register against the same expected values:

```bash
make pipe
```

```
ok   x1 = 00000005   ok   x2 = 00000007   ok   x3 = 0000000c
ok   x4 = 00000002   ok   x5 = 0000000c   ok   x6 = 00000063
ok   x7 = 00000000   ok   x8 = 00000001   ok   x9 = 00000030
ok   mem[0] = 0c
ALL TESTS PASSED (pipeline matches single-cycle)
```

Every value matches the single-cycle core — including `x5=12` (a store→load
round trip through MEM), `x6=99` (a not-taken branch), and `x7=0` (a *taken*
branch that flushed the instruction which would have set it). And `make pipe-sum`
runs the sum-loop, whose `sum += i` / `i++` form back-to-back dependency chains
that exercise forwarding every iteration — still 55.

## What this core leaves out (good next projects)

- **CSRs / interrupts in the pipeline.** Precise exceptions in a pipeline (so
  `mepc` points at exactly the right instruction when several are in flight) are
  genuinely subtle; this pipelined core is RV32IM only, while the single-cycle
  `cpu_core.v` keeps the interrupt support from Step 15. Merging them is a real
  project.
- **Branch prediction** to remove the taken-branch penalty.
- **A multi-cycle divider** with a proper stall, instead of combinational divide.
- **Hazard-aware CSR/`fence`/`ecall`** handling.

But the heart of a modern CPU — overlapped execution with forwarding, stalls,
and flushes keeping it correct — is now real and verified against the reference
single-cycle design.

## Takeaway

Pipelining doesn't change *what* the CPU computes, only *how fast*. The entire
job is the bookkeeping that preserves single-cycle semantics while five
instructions overlap: forward when you can, stall when you must, flush when you
guessed wrong.
