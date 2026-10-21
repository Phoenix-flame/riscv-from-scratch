# Step 42 — Unifying the cores: one pipeline with every feature

By Step 41 the project had a fast core and a featureful core, and they were
different cores. The 5-stage pipeline (Steps 17–20) runs close to one
instruction per cycle, but it knows only RV32IM, machine mode, and two ideal
memories that answer instantly. Everything built since lived on the slower
cores:

- atomics (Step 26) on the single-cycle core;
- user mode (21), the MMU (22, 24) and the TLBs with translated fetch (41) on
  the multi-cycle cores.

Anything that needed both speed and features had to pick one.

This step folds them all into the pipeline. `rtl/cpu_pipe_u.v` is a 5-stage
**RV32IMA + Zicsr** core with **machine and user mode**, an **Sv32 MMU that
translates both fetch and data**, **split I/D TLBs** with `sfence.vma`, and —
the change that matters most for what comes next — **memory ports that can
stall**.

| | `cpu_pipe_trap` (20) | `cpu_mc_tlb` (41) | **`cpu_pipe_u` (42)** |
|---|---|---|---|
| organisation | 5-stage pipeline | multi-cycle FSM | 5-stage pipeline |
| ISA | RV32IM | RV32IM | **RV32IMA** |
| privilege | M | M + U | **M + U** |
| translation | — | fetch + data, I/D TLBs | **fetch + data, I/D TLBs** |
| memory | ideal, combinational | registered BRAM | **ready/valid (ideal, BRAM via a cache, …)** |

The older cores are untouched. Everything here is a new file plus a new SoC,
`rtl/soc_pipe_u.v`, with the same memory map and peripherals as the MMU SoCs.

## Stall-capable ports

The old pipeline had two hard-wired memories: a combinational `imem` inside the
core and a combinational `dmem` outside it. Neither could say "not yet". The
new core has two ports with one rule:

```
i_addr, i_req           -> i_rdata, i_ready
d_addr, d_req, d_we[3:0], d_wdata -> d_rdata, d_ready
a request completes in the cycle where req & ready; read data is valid then
```

Ideal memory ties `ready` high, which is what `soc_pipe_u` does. A cache drives
`ready` high on a hit and low through a refill (Step 43). The core reacts in two
different ways, because the two ports sit at different ends of the pipe:

- **I-port not ready:** IF has no instruction this cycle, so it puts a
  bubble into ID and holds the PC. Everything older keeps moving, so the
  pipeline drains instead of stopping.
- **D-port not ready:** the instruction in MEM cannot finish, and nothing
  behind it can overtake it. The whole pipe **freezes**: every pipeline
  register holds, and MEM/WB takes a bubble.

Freezing raises the question that every stall-capable pipeline has to answer:
*what happens to things that commit?* Traps, CSR writes, `mret`, `sfence.vma`
and branch redirects all commit in EX. If EX is frozen for five cycles, a trap
must enter its handler once, not five times. (Taking it twice would set
`MPIE <= MIE` twice, and the second copy would record the already-cleared MIE.)
So every EX-stage side effect is gated by one signal:

```verilog
assign ex_go   = idex_valid & ~freeze & ~ex_hold;
assign take_trap = ex_go & (exception | irq_take);
wire   csr_commit = ex_go & idex_is_csr & ~take_trap;   // ... and so on
```

`ex_go` is true on exactly one cycle per instruction: the cycle it leaves EX.

The second freeze hazard is subtler. EX gets its operands from the forwarding
network: from EX/MEM, from MEM/WB, or from what ID read. While EX waits, the
producer in WB retires and its forwarded value disappears. On the next cycle EX
would read the stale ID-time copy. The fix is to re-latch the forwarded
operands into ID/EX on every held cycle:

```verilog
end else if (freeze || ex_hold) begin
    idex_rs1d <= opA; idex_rs2d <= opB;     // keep what forwarding sees now
```

The value is captured on the first held cycle and kept from then on, whatever
retires meanwhile.

## Atomics in MEM

An AMO is a read-modify-write, so it needs two requests on the D-port. MEM
issues them back to back. Phase 0 reads and latches the old value, and the
pipe stays frozen. Phase 1 writes `old ⊕ rs2`, where ⊕ is the AMO's operation:
swap, add, and/or/xor, or signed/unsigned min/max. Then the AMO retires with
the *old* value in `rd`. Because the pipe is frozen for the whole sequence,
nothing can observe the half-done AMO.

LR and SC need a reservation register. LR sets it to its address when it
completes in MEM. SC checks it in MEM: on a match it stores and writes 0, and
otherwise it skips the store and writes 1. Both SC and AMOs clear the
reservation, and so does any trap. A context switch is a trap, so a task can
never complete an SC on a reservation another task took. MEM runs in program
order, so this is exact.

AMO results come from MEM, so the existing load-use interlock covers them by
marking every AMO as a load (`idex_mem_read`). Their address is `rs1` with no
offset, picked from the forwarded `opA` rather than from the ALU.

## Translation, and why it is in EX

There are two lookups per instruction, and each is in the stage that already
holds its address:

- **Fetch:** IF looks up the PC in the I-TLB. On a hit, `i_addr` is the
  physical address, and the hit adds no cycles.
- **Data:** EX looks up the effective address in the D-TLB, right after the
  ALU. The physical address goes into EX/MEM with the rest of the instruction.

Putting data translation in **EX** rather than MEM makes page faults
**precise for free**. The pipeline already commits every trap in EX (Step 20).
An instruction is older than everything behind it and younger than everything
in MEM/WB, and those older instructions have already passed the point where
they could commit anything. A data fault found in EX is just one more exception
source in the same place:

```verilog
wire [31:0] trap_cause = idex_ifault ? 32'd12 :                 // fetch PF
                         ex_illegal  ? 32'd2  :
                         idex_ecall  ? (in_user ? 32'd8 : 32'd11) :
                         idex_ebreak ? 32'd3  :
                         ex_dfault   ? (need_w ? 32'd15 : 32'd13) : // store/AMO, load
                                       32'h8000_0007;
```

A **fetch** fault is found in IF, which is too early to trap: an older branch
in EX might be about to redirect, and then the fault never happened. So IF does
not trap. It sends a **fault token** down the pipe: a NOP tagged `ifault`. If
the token reaches EX without being flushed, it traps there with `mcause = 12`
and `mepc = its PC`. If an older instruction redirects first, the token is
flushed with the rest of the wrong path.

Permissions are checked in the core, not in the TLB. Fetch needs `U` and `X`.
A load or LR needs `R`. A store, SC or AMO needs `W`, and an AMO needs `R` as
well. A failed store-side check is cause 15, as the spec defines AMO faults.

## One walker, borrowing the D-port

A miss needs a page-table walk, and the multi-cycle cores ran theirs as extra
FSM states. A pipeline has no such FSM, so the walk lives in its own small
engine, `rtl/ptw.v`. It has three states (`IDLE → L1 → L0`), and each read is
one request on the D-port held until `ready`. PTEs are therefore read through
whatever sits on that port, including the D-cache in Step 43, as on real
hardware.

Both TLBs share the walker, and each kind of miss stalls in its own way:

- **D-TLB miss:** EX is *held* (`ex_hold`). IF and ID hold, and bubbles go
  into MEM. The walk starts once MEM is not using the port, and it fills the
  D-TLB. On the next cycle EX hits and moves on.
- **I-TLB miss:** IF just has no instruction, exactly as for an I-cache miss.
  Older instructions keep flowing. The walk starts once MEM is idle, which
  happens within a few cycles because nothing new enters the pipe.

The arbitration rule makes this safe: the walker only *starts* in a cycle when
MEM is not using the port, and once it has started, MEM waits for it. So
neither side is ever cut off in the middle of a transfer, and a slow cache
refill on a PTE read is just a longer wait. Data walks win ties, because they
belong to the older instruction.

Two details close the gaps:

- **Faults have nowhere to go.** A bad PTE produces no leaf to put in a TLB, so
  the walker records it in a one-entry register: *the last walk of this VPN on
  this side found nothing*. The requester then faults, from EX directly or
  through a fetch fault token. Any trap or `sfence.vma` clears the register.
- **Wrong-path fetch walks.** An I-TLB miss on a path that a branch then
  abandons would fill a translation nobody asked for. That would be harmless,
  but it would also be wrong if the redirect was a trap into M-mode. So a
  redirect *kills* an in-flight fetch walk: it finishes its current read (the
  port is never dropped mid-transfer) and discards the result.

`satp` cannot change under a live walk. Only M-mode can write it, M-mode is
never translated, and every privilege change flushes the pipeline. A fetch walk
still finishing its read after the trap into M-mode has already been killed,
so its result is dropped.

## Tests

`make pipe-u` runs four checks:

```
---- Step 42: Step 41 TLB demo on the unified pipeline ----
TLB
IPF
  cycles 1339  retired 831  (CPI 1.61)  page walks 6
PIPE-U TLB: ALL PASS (Step 41 demo, unchanged, on the pipeline)

  cycles 19573  retired 12556  (CPI 1.55)
PIPE-U PROG: PASS (374 bytes match)

---- Step 42: isolated processes on the unified pipeline (fetch translated, TLBs, sfence.vma) ----
AAAAbbbbAAAAbbbbAAAAbbbbAAAAbbbbAAAAbbbbAAAbbbAAAAbbbbAAAAbbbbAAAAbbbbAAAAbbbbAAAAbbbbAAAbbb
A-runs=46  b-runs=46  haltcycles=37533
PIPE-U SCHED: ALL PASS (preemption + per-task isolation)

  rv32ui 40/40   rv32um 8/8   rv32ua 10/10      total 58/58   ALL PASS     (pipe_u)
  rv32ui 40/40   rv32um 8/8   rv32ua 10/10      total 58/58   ALL PASS     (pipe_u_vm)
```

1. **The Step 41 TLB demo, unchanged** (`sw/tlb.hex`, `tb/pipe_u_tlb_tb.v`).
   The same image and the same pass criteria: code runs from a remapped
   execute-only page, the stale store lands in the old page until
   `sfence.vma`, and the run ends in a fetch fault with `mcause` 12 at
   `0x00406000`. It takes 1339 cycles here, against 2050 on `cpu_mc_tlb`.
2. **Atomics** (`sw/at.hex`, `tb/pipe_u_prog_tb.v`). The Step 26 demo, which
   runs every AMO plus LR/SC and a spinlock. Its UART output is compared
   byte-for-byte against the reference single-cycle core
   (`tb/atomic_expected.txt`).
3. **Isolated processes with fetch translation** (`sw/smmu_vm.hex`,
   `tb/pipe_u_sched_tb.v`). Step 38's two-task scheduler, rebuilt with
   `-DSCHED_VM`. The build maps the shared code page execute-only, and adds an
   `sfence.vma` after each `satp` switch. It covers timer interrupts preempting
   U-mode, per-task page tables, and both TLBs. The default build is unchanged,
   and `make sched-mmu` still runs it on `cpu_mc_mmu`. In the same 24 timer
   ticks the pipeline gets through 46 task passes, against 17.
4. **riscv-tests twice.** `pipe_u` runs the suite as every core sees it.
   `pipe_u_vm` builds it with `-DRVTEST_VM` (Step 41), so the test body runs in
   U-mode with Sv32 on and every fetch, load, store and AMO is translated. Both
   pass 58/58 across rv32ui/um/ua. `fence_i` and `ma_data` are the usual
   documented gaps (write-once ROM; word RAM).

The fence in test 3 is not decoration. With the code mapping but **without**
the `sfence.vma`, the same run fails:

```
FAIL: task A private page = b000002e (expected 0xA.......)
FAIL: task B private page = 00000000 (expected 0xB.......)
```

Task B's stores to VA `0x1000` hit the D-TLB entry left by task A, and land in
*task A's* physical page. Step 38's argument for not needing the fence was "no
TLB, so nothing to invalidate", and that argument is gone.

## Honest status

- Verified in simulation only, on ideal memory. Combinational reads of 16–32 KB
  arrays are not block RAM. Making the memory real is exactly the next step:
  caches in front of slow memory, with no change to the core.
- No ASIDs, no `G` bit, no `mtval`, A/D bits ignored, no misaligned-superpage
  check. All of these are as in Step 41.
- No supervisor mode, and no branch predictor. Both were folded in later, by
  Step 44.
- Misaligned loads and stores are silently wrong (word RAM), as on the
  multi-cycle cores. `aq`/`rl` are ignored: with one hart and in-order memory,
  every AMO is already sequentially consistent.

## Takeaway

The features merge cleanly once each one sits in the stage that already has
what it needs. Data translation goes in EX, beside the ALU and the trap logic,
so its faults are precise for free. A fetch fault travels as a token and traps
when it reaches EX. Atomics take two requests in MEM, the one stage that owns
memory order. The walker is a separate engine that borrows the D-port only
when MEM is idle. The real change is the bus, not the features: once a memory
can say "not yet", the pipeline has to freeze correctly, and the rest follows.
That makes the next step possible.
