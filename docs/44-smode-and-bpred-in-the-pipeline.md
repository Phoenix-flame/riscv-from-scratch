# Step 44 — Supervisor mode and the branch predictor, folded into the pipeline

Step 42 unified most of the project in one core, `cpu_pipe_u`: the 5-stage
pipeline with atomics, user mode, and the Sv32 MMU with translated fetch and
TLBs. Two features were still left on their own cores:

- **supervisor mode** with `medeleg`/`mideleg` trap delegation (Step 39), on
  `cpu_mc_s`, a multi-cycle core with no MMU;
- the **branch predictor**, a BTB with 2-bit counters (Step 32), on
  `cpu_pipe_bp`, a pipeline with none of the later features.

This step puts both into `cpu_pipe_u`. It is the same core in the same file, so
everything built on it so far now gets them: the ideal-memory SoC
(`soc_pipe_u`), the cached SoC (`soc_pipe_c`) and the riscv-tests harnesses.
The predictor is a parameter (`BPRED`, default 1), so its effect can be
measured on an otherwise identical core.

The result has every privilege, memory-system and prediction feature in the
project, in one place. (The C and F extensions, Steps 34/35, and the debug
module, Step 29, are still on their own cores.)

| feature | from | in `cpu_pipe_u` |
|---|---|---|
| 5-stage pipeline, forwarding, precise traps | 17, 20 | ✓ |
| RV32M | 16 | ✓ |
| RV32A (LR/SC, AMOs) | 26 | ✓ (42) |
| M/U privilege | 21 | ✓ (42) |
| Sv32 MMU, translated fetch, I/D TLBs, `sfence.vma` | 22, 24, 41 | ✓ (42) |
| stall-capable buses, I/D caches | 42, 43 | ✓ |
| **S-mode, `medeleg`/`mideleg`, `sret`, `stval`** | 39 | **✓ (44)** |
| **BTB + 2-bit branch prediction** | 32 | **✓ (44)** |

## Supervisor mode

The CSR side already existed. `rtl/csr_s.v` (Step 39) holds the S-level
registers: `sstatus`, `sie` and `sip` as masked views of the machine
registers, plus `stvec`, `sepc`, `scause`, `stval` and `sscratch`. It also
holds `medeleg`/`mideleg` and makes the delegation decision. The pipeline swaps
`csr.v` for it. The work is in what the pipeline has to do differently now that
there is a third privilege level.

**Decode and privilege checks**, all in EX where every trap commits:

- `sret` is decoded. It needs S or above, and it redirects to `sepc`. Like
  `mret`, it is never interrupted mid-return.
- A CSR access is illegal if the address's bits `[9:8]` name a higher privilege
  than the current one. That is the spec's rule, and it replaces Step 42's "U
  can't touch any CSR".
- `mret` needs M. `sfence.vma` needs S or M.
- `ecall` reports its origin: cause 8 from U, 9 from S, 11 from M.

**Where traps go.** On a trap, `csr_s` checks the cause against `medeleg` (for
exceptions) or `mideleg` (for interrupts). If the bit is set and the trap was
taken below M, it vectors to `stvec` and enters S. The pipeline only has to
redirect to that trap vector instead of always to `mtvec`. Interrupt priority
and per-level enables are `csr_s`'s too. A machine interrupt is always enabled
while running below M, which the old `csr.v` did not model. The pipeline gives
it the cause through `irq_cause`.

**`mtval` / `stval`** are new to the pipeline. Step 42 had no way to tell a
kernel *which* address faulted. EX now supplies a trap value: the faulting
virtual address for a page fault, the instruction bits for an illegal
instruction, and the PC for `ebreak` and fetch faults. ID/EX carries the
instruction word for that purpose. A demand-paging handler needs exactly this.

**Translation in S.** With `satp.MODE = 1`, S-mode is translated too, so
`vm_on` is now "not M and Sv32 on". The permission rules gain the S/U split:

| access | U-mode needs | S-mode needs |
|---|---|---|
| fetch | `X`, `U=1` | `X`, `U=0` (S never executes user code) |
| load / LR | `R` (or `X` if MXR), `U=1` | `R` (or `X` if MXR), `U=0` — or `U=1` if **SUM** |
| store / SC / AMO | `W` (+`R` for AMO), `U=1` | `W` (+`R`), `U=0` — or `U=1` if **SUM** |

SUM and MXR live in `mstatus` and are visible through `sstatus`. `csr_s` gains
them in its `sstatus` mask, and two outputs pass them to the core. On
`cpu_mc_s`, which has no MMU, they are simply unused.

## The branch predictor

`rtl/branch_predictor.v` is reused unchanged: a 64-entry tagged BTB and 2-bit
counters, looked up combinationally with the IF-stage PC. It is wired in the
same way as in Step 32:

- **IF:** on a BTB hit with a taken counter, the next PC is the BTB target;
  otherwise it is PC+4. The guess (taken?, target) rides down the pipe in
  IF/ID and ID/EX.
- **EX** checks the guess against what the instruction actually does. It is
  wrong if a branch went the other way, or if a taken branch went somewhere
  other than the predicted target. One case the Step 32 core never needed:
  it is also wrong if a **non-control instruction was predicted taken**. With
  translation, the same VA can hold different code in different address
  spaces, so a BTB entry can match an instruction that is not a branch at all.
  Every wrong guess redirects to the true next PC: the target if taken, else
  PC+4. Only wrong guesses flush, so a correctly predicted taken branch costs
  nothing.
- **Training** happens in EX, gated by `ex_go` like every other EX side effect.
  A branch held in EX by a D-TLB walk, or frozen by a cache miss, trains its
  counter once, on the cycle it leaves EX.

The predictor is indexed by **virtual** PC and never sees privilege or `satp`.
That is safe, because a prediction is only a guess: EX checks every one, and a
stale entry after a context switch costs one misprediction. A guess can also
send IF to a page it may not execute. The resulting fetch-fault token is just
one more wrong-path instruction, flushed by the misprediction before it reaches
EX.

## Tests

`make pipe-u-sv` runs the new checks, and every earlier test of the unified
core still runs on it.

**1. An S-mode kernel, translated, handling its user's page faults**
(`sw/sv_demo.c`, `sw/sv_asm.S`, `tb/pipe_u_sv_tb.v`). This is the shape xv6
needs.

M builds one address space: kernel pages with `U=0`, user code execute-only at
VA `0x3000`, a user data page, and an unmapped page. It delegates the U
`ecall` and all three page-fault causes to S, turns translation on, and drops
to S. From then on:

```
---- Step 44: S-mode kernel, translated, serving user page faults ----
S:u!
  435 cycles
PIPE-U SV: ALL PASS (SUM, demand paging, fetch fault -- all handled in S)
```

- **SUM.** The S kernel reads the user page with SUM=0. That is a load page
  fault taken *from S to S* (`stval = 0x4000`); the handler skips the load.
  With SUM=1 the same load returns the page's contents.
- **System calls.** The user prints through `ecall`s that S serves (cause 8,
  delegated).
- **Demand paging.** The user stores to VA `0x5008`, which is unmapped. That is
  a store page fault in S with `scause = 15` and `stval = 0x5008`. The handler
  writes the PTE, runs `sfence.vma` on that VA, and returns *without* advancing
  `sepc`. The store retries and lands in PA `0x5008`, and the read-back agrees.
- **Killing the task.** The user jumps to a mapped but non-executable page.
  That is cause 12 in S, with `stval = sepc = 0x6000`. The kernel then makes an
  `ecall` to M (cause 9, not delegated) to shut down. M sees that one trap and
  nothing else.

The test has teeth. A core that ignores SUM fails three checks, and one that
never delegates fails 14 of the 15.

**2. The Step 39 delegation demo, unchanged** (`sw/smode.hex`,
`tb/pipe_u_smode_tb.v`). It covers U `ecall` → S, illegal instruction → S, a
supervisor software interrupt via `mideleg` → S, and S `ecall` → M, with the
same counts as on `cpu_mc_s`.

**3. The predictor, on and off** (`tb/pipe_u_bp_tb.v`). Each program runs on
two copies of `cpu_pipe_u` that differ only in `BPRED`:

```
---- Step 44: branch predictor in the unified pipeline ----
  bpred bench, not-taken  ctrl  6183  mispredicted  3544 (57.3%)  cycles  23067
  bpred bench, BTB+2-bit  ctrl  6183  mispredicted   879 (14.2%)  cycles  17737
  cache bench, not-taken  ctrl 14887  mispredicted 10054 (67.5%)  cycles  89877
  cache bench, BTB+2-bit  ctrl 15107  mispredicted   329 (2.1%)  cycles  71307
  speedup: bpred bench 1.30x   cache bench 1.26x
```

On Step 32's own benchmark, the unified core reproduces `cpu_pipe_bp` almost
exactly: 3544 → 879 mispredictions, and 23067 → 17737 cycles against Step 32's
23068 → 17737. On Step 43's cache benchmark the predictor removes 97% of the
flushes. The control-transfer counts differ slightly between the two runs only
because the faster core spends more iterations polling the UART.

**4. Everything that already ran on the core** now runs with S-mode logic and
the predictor (`BPRED=1`):

- `make pipe-u`: the Step 41 TLB demo, atomics, isolated processes, and
  riscv-tests in M and with Sv32 on in U. The TLB demo drops from 1339 to 1161
  cycles with the predictor.
- `make cache`: the cache sweep, the D-cache unit test, and riscv-tests through
  the caches.
- `tb/cache_sys_tb.v` now also runs the S-mode kernel demo through 256-byte
  caches at latency 7. The kernel's demand-paging PTE store is still dirty in
  the D-cache when the walker re-reads it, and it is found there.

## Honest status

- Verified in simulation only.
- `rv32si` (the supervisor riscv-tests) does not run yet. Its tests need
  upstream's S-mode environment hooks, which our `p` environment dropped. They
  also need things this MMU does not do: hardware A/D-bit updates (`dirty`) and
  misaligned-fetch exceptions (`ma_fetch`).
- Still no ASIDs or `G` bit, no hardware A/D updates, and no `mstatus.MPRV`,
  `TVM`, `TW` or `TSR`. There is no S-mode timer (Sstc) either: the timer is
  machine-only, as in Step 39.
- No return-address stack. `ret` is predicted from the BTB entry its last
  execution left, which is right for single-call-site functions and wrong
  otherwise.

## Takeaway

Both features slotted in where they belong without disturbing anything around
them. S-mode adds checks and one more return instruction to EX, where every
trap and privilege decision already lives, plus a second column of permission
rules in the TLB check. The predictor steers IF and is audited in EX, with its
training gated by the same `ex_go` that already made frozen instructions commit
exactly once. Supervisor mode, delegation, `stval` and translation in S are
exactly what an xv6-style kernel expects from its hardware, and all of it now
runs on the fast core.
