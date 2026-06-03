# Step 26 — The A extension: atomic memory operations

Locks, lock-free data structures, and most of what an RTOS or SMP kernel needs
for synchronization rest on **atomic** memory operations — read-modify-write
sequences that can't be interrupted partway. RV32A adds them. This step
implements the full set on the single-cycle core.

All A-extension instructions share one opcode (`0101111`) with `funct3 = 010`
(word). The operation lives in `funct7[6:2]` (a 5-bit "funct5"); the remaining
two bits are `aq`/`rl` ordering hints, which are **no-ops on a single in-order
hart** — there's only one core and it never reorders memory, so the strongest
ordering is already free.

## Two families

**AMOs** (`amoadd`, `amoswap`, `amoand`, `amoor`, `amoxor`, `amomin`, `amomax`,
`amominu`, `amomaxu`): atomically load the word at `rs1`, write back
`op(old, rs2)`, and return the **old** value in `rd`. On a single-cycle core this
is almost free: the data memory already reads combinationally, so in one cycle we
read the old value, compute the new one, and assert the write — `rd` gets the old
value, memory gets the new value on the same clock edge.

```verilog
case (amo_f5)
    5'b00000: amo_alu = mem_rdata + rs2_data;   // AMOADD
    5'b00001: amo_alu = rs2_data;               // AMOSWAP
    5'b10000: amo_alu = ($signed(mem_rdata) < $signed(rs2_data)) ? mem_rdata : rs2_data; // AMOMIN
    // ... and so on
endcase
assign dmem_addr  = is_amo_op ? rs1_data : alu_result;  // address is rs1, no immediate
assign dmem_wdata = is_amo_rmw ? amo_alu : rs2_data;
```

**LR/SC** (`lr.w`, `sc.w`): the reservation primitive. `lr.w` loads a word and
*registers a reservation* on its address. `sc.w` stores **only if** the
reservation is still valid for that address, writing 0 to `rd` on success or 1 on
failure. It's the building block for compare-and-swap and lock-free loops:

```
retry:  lr.w   t0, (a0)      # load + reserve
        addi   t0, t0, 1
        sc.w   t1, t0, (a0)   # store iff still reserved
        bnez   t1, retry      # failed? try again
```

The reservation is one register pair (`resv_valid`, `resv_addr`). It's set by
`lr.w`, and cleared by `sc.w`, by any AMO, and — crucially — **by taking a
trap**. That last rule is what makes LR/SC correct under preemption: if the
scheduler (Step 25) switches tasks between an `lr` and its `sc`, the trap clears
the reservation, the `sc` fails, and the loop retries. Without it, a task could
"succeed" a store based on a value another task had already changed.

## Why this matters here

On a single hart, a lone AMO is automatically safe against preemption — it's one
instruction, and an interrupt can only be taken at an instruction boundary, never
in the middle of the read-modify-write. So `amoadd` on a shared counter can never
lose an update, whereas a plain load/add/store can be torn apart by a timer tick
landing between the load and the store. That's exactly the bug a preemptive
scheduler introduces and atomics fix. With multiple harts, the same instructions
(plus the `aq`/`rl` bits we currently ignore) provide cross-core ordering.

## Verifying it

`make atomic` runs `sw/atomic_demo.c`, which uses inline assembly (so the real
instructions are emitted, not a library fallback) and prints each result:

```
amoadd : old=10 now=15   (want 10,15)
amoswap: old=15 now=99   (want 15,99)
amoor  : now=ff       (want ff)
amoand : now=f        (want f)
amoxor : now=55       (want 55)
amomax : now=3        (want 3)     <- signed max(-5, 3)
amomin : now=-5       (want -5)
lr/sc  : loaded=42 sc=0 now=43  (want 42,0,43)   <- reservation live: success
sc again: sc=1 now=43          (want 1,43)       <- no reservation: fails, no write
lock   : prev=0 held=1        (want 0,1)         <- amoswap spinlock acquire
RV32A OK
```

The second `sc.w` failing (and leaving memory unchanged) is the important one: it
shows the reservation really is consumed and that a store-conditional without a
live reservation does nothing.

## Implementation notes / limits

- It's wired into the single-cycle `cpu_core` (and the shared `control` decode).
  The multi-cycle and pipelined cores don't have the atomic datapath yet; adding
  it there is the same idea (AMO = read old, write computed) plus, for the
  pipeline, making sure the read-modify-write isn't split across a hazard.
- Atomics target RAM (the combinational-read/edge-write path). Pointing an AMO at
  a peripheral isn't meaningful here.
- A normal store to a reserved address doesn't clear the reservation in this
  implementation — only SC, AMO, and traps do. That's spec-legal (SC is allowed
  to succeed there) and correct for single-hart lock code; a stricter
  multi-hart implementation would also clear on conflicting stores.

## Where this leads

With atomics in place, the synchronization layer an RTOS needs is real: you can
build a mutex (`amoswap`-based spinlock or an LR/SC loop), a semaphore, or a
lock-free queue. Combined with the timer tick and context switch from Step 25,
that's the substrate FreeRTOS's RISC-V port sits on — which is the natural next
target once a couple more pieces (a bigger RAM and a 64-bit `mtime`) are in place.

## Takeaway

Atomicity on a single in-order core is mostly about *where the boundaries are*: an
AMO is one uninterruptible instruction, and LR/SC turns "did anyone interfere?"
into a single reservation bit that a trap is honest enough to clear. The hardware
is small; the guarantee it provides is what makes shared-memory software possible.
