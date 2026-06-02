# Step 20 — Precise exceptions in the pipeline

The single-cycle core handles one instruction at a time, so trapping is easy:
there's exactly one instruction "in flight," and `mepc` obviously points at it.
In a pipeline, **five instructions are in flight at once**. When one of them
traps, what does `mepc` point to? Which instructions should complete, and which
should be thrown away? Getting this right is called **precise exceptions**, and
it's the hard part of pipelined trap support.

This step builds `rtl/cpu_pipe_trap.v` — the Step-17 pipeline plus CSRs,
interrupts, `ecall`, and illegal-instruction detection — and verifies it runs
the Step-15/18/19 trap programs with output identical to the single-cycle core.

## What "precise" means

When instruction *I* traps, the architectural state handed to the handler must
look exactly as if:

- every instruction **older** than *I* (further along the pipe) completed, and
- *I* and every instruction **younger** than it did **not** execute at all,
- with `mepc` naming *I* (or, for an interrupt, the instruction that would have
  run next).

If that invariant holds, the handler can do its job and `mret` back as if
nothing was overlapped. If it doesn't, you get corrupted state — a register
half-updated, a store that shouldn't have happened, or a return to the wrong PC.

## The strategy: commit traps at one stage

The clean way to get precision is to pick a single **commit point** and take all
traps there. This core uses the **EX stage**. When the instruction in EX traps:

```verilog
wire exception = idex_valid & (idex_illegal | idex_ecall | idex_ebreak);
wire irq_take  = idex_valid & irq_pending & ~exception & ~idex_is_mret & ~idex_is_csr;
wire take_trap = exception | irq_take;
// mepc = idex_pc;  squash this instruction;  flush younger;  PC <- mtvec
```

Because EX is "downstream" of IF and ID but "upstream" of MEM and WB:

- instructions in **MEM/WB** (older) are past EX and complete normally — they're
  the ones that already ran;
- the trapping instruction in EX is **squashed** (its EX/MEM register is turned
  into a bubble, so it writes no register and no memory);
- instructions in **ID/IF** (younger) are **flushed** to bubbles;
- `mepc` is set to the EX instruction's own PC.

Our only exception sources (illegal, `ecall`, `ebreak`) are all detectable by
the time an instruction reaches EX, and interrupts can be injected at EX on any
in-flight instruction, so committing at EX is sufficient for a precise state.
`mret` and CSR access are handled at EX too (CSR read/write happens there; `mret`
redirects to `mepc` and restores `mstatus`).

## Two bugs the pipeline exposed (and how they were found)

Pipelining turns "obviously correct" single-cycle logic into something with
timing corners. Two real bugs showed up during bring-up; both are instructive.

### Bug 1 — a forwarding mux that intermittently dropped a forward

The `ecall` demo printed `hhello…` — the first character doubled. Tracing showed
the loop's pointer-increment result (`addi a5,a5,1`) was sitting in the EX/MEM
register, flagged for forwarding, yet the dependent `lbu` next door read the
**stale** `a5` anyway. Worse, the *same signal at the same cycle* read different
values on different runs — a dead giveaway for a **simulation race**.

The cause: forwarding had been written as a Verilog **function** called from a
continuous assignment. A function call's sensitivity only tracks its explicit
arguments, not the module registers it reads inside (`exmem_rd`, `exmem_result`,
…), so the forward mux didn't reliably re-evaluate when those changed. The fix
is to express forwarding as plain combinational logic whose sensitivity the
simulator tracks correctly:

```verilog
// not a function — plain continuous assigns, correct sensitivity
wire fwdA_exmem = exmem_reg_write && exmem_rd!=0 && exmem_rd==idex_rs1;
wire fwdA_memwb = wb_reg_write    && wb_rd!=0    && wb_rd==idex_rs1;
wire [31:0] opA = fwdA_exmem ? exmem_result : fwdA_memwb ? wb_data : idex_rs1d;
```

(The plain Step-17 pipeline had the same latent bug; its simpler test programs
just never hit the timing that exposed it. It's fixed there too.)

### Bug 2 — interrupts taken on a flush "filler" instruction

With forwarding fixed, the interrupt demo printed `main: ena` over and over. The
trace showed interrupts being taken with `mepc = 0x00000000`, so `mret` jumped
to `0x0` (= `_start`) and restarted `main` endlessly.

The cause: when a branch/`mret`/trap flushes IF/ID, it injects a NOP **with
`pc = 0`**. Two cycles later that filler NOP reaches EX as a *valid-looking*
instruction. An asynchronous interrupt taken on it recorded `mepc = 0` — its
bogus PC. The fix is to track whether an IF/ID slot holds a real fetched
instruction, and to not let interrupts commit on a filler:

```verilog
// IF/ID carries a validity bit; flush-injected NOPs are not valid
if (rst || flush) ifid_valid <= 1'b0;       // filler -> not interruptible
else if (stall)   ifid_valid <= ifid_valid;
else              ifid_valid <= 1'b1;
// ... idex_valid <= ifid_valid;  and  irq_take requires idex_valid
```

This is precisely the "which instruction owns the interrupt" question that
*precise* exceptions are about — an interrupt must land on a real instruction
boundary with a real PC, never on a pipeline artifact.

## Verification: identical behavior to the single-cycle core

A pipelined trap implementation is correct only if it's architecturally
indistinguishable from the simple core. All three trap programs now produce
identical output on both:

```bash
make pipe-ecall     # -> hello via ecall syscalls!
make pipe-illegal   # -> TRAP! mcause=2 ... mepc=0x88
make pipe-irq       # -> main: observed 5 timer interrupts
```

The `kprintf`-heavy `soc_demo` (function pointers, software division, format
specifiers) also runs cleanly on the pipelined core — the same program, the same
output, just overlapped execution underneath.

## What's still simplified

- **Commit at EX** suffices because our exceptions are all EX-detectable. A core
  with memory faults (page faults, misaligned-access traps detected in MEM)
  would commit at MEM/WB instead, carrying exception info down the pipe with each
  instruction so the trap is taken at the right boundary.
- **CSR ordering** isn't serialized (no CSR forwarding); it's correct for code
  that doesn't read a CSR in the instruction immediately after writing it, which
  covers ordinary setup/handler code. A stricter core flushes after CSR writes.
- **No nested interrupts / privilege levels** — single machine-mode handler.

## Takeaway

Precise exceptions are a bookkeeping discipline: pick one commit point, let older
instructions finish, squash the trapping one, flush the younger ones, and make
`mepc` name exactly one real instruction boundary. The two bugs here — a dropped
forward and an interrupt on a phantom instruction — are exactly the kinds of
timing corners that don't exist in a single-cycle design and that make pipelined
trap support genuinely subtle.
