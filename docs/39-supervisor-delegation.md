# Step 39 — Supervisor mode and trap delegation

Until now the core had two privilege levels and exactly one trap destination.
Machine mode ran everything important; user mode ran the application; and every
trap — an `ecall`, an illegal instruction, a timer interrupt — landed in the
machine-mode handler at `mtvec`. That is the wrong shape for a real operating
system. A Unix-like kernel does not want to live in machine mode: machine mode
is the firmware rung, the monitor that owns the physical machine and should be
entered as rarely as possible. The kernel wants to live one rung down, in
**supervisor mode**, and it wants the common traps — the system calls, the page
faults, the timer tick that drives preemption — delivered straight to it,
without a detour through the firmware on every single one.

`medeleg` and `mideleg` are the two registers that make that split real. They
are bit-per-cause masks: if a trap happens below machine mode and the bit for
its cause is set in the delegation register, the hardware vectors the trap to
the supervisor handler at `stvec` instead of `mtvec`, updates the supervisor
trap CSRs instead of the machine ones, and enters S-mode instead of M-mode.
Machine mode never runs. The rare event that *isn't* delegated — a genuine
machine-level fault, or an `ecall` issued from S-mode asking the monitor for a
service — still goes to M, which is exactly the division of labour an OS wants.

This step adds S-mode (`cpu_mc_s`, `csr_s`) and demonstrates the routing with an
`ecall`, an illegal instruction, and a software interrupt all delegated to a
small S-mode kernel, contrasted against an `ecall` from S that is not.

## The privilege ladder and the supervisor CSRs

Privilege is a two-bit field: `2'b11` for machine, `2'b01` for supervisor,
`2'b00` for user. The numeric ordering is deliberate — `M > S > U` as plain
unsigned integers — so a privilege check is a single comparison. A CSR's minimum
privilege is encoded in its address bits `[9:8]`, and the core may touch it only
when `cur_priv >= csr_addr[9:8]`. That one rule replaces the old blanket "any
CSR in user mode is illegal": S-mode can now read and write its own CSRs and the
user CSRs, but reaching for a machine CSR from S-mode is an illegal instruction.
`mret` requires machine mode; the new `sret` requires at least supervisor.

Supervisor mode does not get a fresh, independent set of status and interrupt
registers. `sstatus`, `sie`, and `sip` are restricted **views** of the machine
registers `mstatus`, `mie`, and `mip` — the same physical bits, masked down to
the subset an S-mode kernel is allowed to see and change. Reading `sstatus`
returns `mstatus` ANDed with the supervisor-visible mask; writing it changes
only those bits and leaves the machine-only bits (`MIE`, `MPIE`, `MPP`) alone.
This is why the implementation keeps one `mstatus` register and derives the
supervisor view from it, rather than trying to keep two status words coherent.

| CSR | Addr | Role |
|---|---|---|
| `medeleg` | 0x302 | exception causes delegated to S (bit *i* = cause *i*) |
| `mideleg` | 0x303 | interrupt causes delegated to S |
| `sstatus` | 0x100 | masked view of `mstatus`: `SIE`(1), `SPIE`(5), `SPP`(8) |
| `sie`/`sip` | 0x104/0x144 | masked view of `mie`/`mip`: `SSI`(1), `STI`(5), `SEI`(9) |
| `stvec` | 0x105 | supervisor trap vector |
| `sepc`/`scause`/`stval` | 0x141–0x143 | supervisor trap state |
| `sscratch` | 0x140 | supervisor scratch (handler register parking) |

The relevant `mstatus` fields are `SIE`(1), `MIE`(3), `SPIE`(5), `MPIE`(7),
`SPP`(8, one bit), and `MPP`(12:11, two bits). Note the asymmetry: `MPP` records
two bits because a machine trap can come from any of the three levels, but `SPP`
is a single bit because a supervisor trap can only come from S or U.

## The delegation decision and the two trap entries

Routing is one combinational expression. The cause being taken is an interrupt
if its top bit is set; the low bits are the cause number. The trap is delegated
when the core is below machine mode and the matching delegation bit is set:

```
deleg = (priv != M) && (is_interrupt ? mideleg[cause] : medeleg[cause]);
trap_vector = deleg ? stvec : mtvec;
```

The core jumps to `trap_vector`; it no longer hard-wires `mtvec`. The CSR block
then runs one of two trap entries on the clock edge. Delegated to S: `sepc <-
pc`, `scause <- cause`, `stval <- fault value`, `SPIE <- SIE`, `SIE <- 0`, `SPP
<- (came-from-S?)`, `priv <- S`. Not delegated: the original machine entry, with
the `m`-prefixed fields and `priv <- M`. The returns mirror their entries —
`sret` restores `SIE` from `SPIE` and `priv` from `SPP`; `mret` restores `MIE`
from `MPIE` and `priv` from `MPP`. The reason an interrupt must never be taken
on the cycle an `mret` or `sret` retires is unchanged from the machine-only
core: doing so would capture the return instruction's own PC as the new
`epc` and corrupt the privilege stack. Both return instructions are excluded
from the interrupt-taken term.

One subtlety in the interrupt logic is worth stating because it is the whole
point of `mideleg`. An interrupt destined for a *higher* privilege than the one
currently running is always globally enabled — you cannot mask, from user mode,
an interrupt that is going to supervisor mode. It is gated by the enable bit
(`SIE`/`MIE`) only when the target privilege equals the current one. So the
supervisor software interrupt delegated to S fires while the core is in U
regardless of `SIE`, but is held off while the S-handler itself runs with `SIE`
cleared. That is what lets a handler set a pending bit and have the interrupt
delivered cleanly *after* it returns, not recursively inside itself.

## The bug: a function that never re-evaluated

The first build did nothing at all. No UART output, no halt, every result cell
zero. A PC trace showed the core fetching correctly through `main`, executing
the `csrw` instructions that set up `medeleg`, `mtvec`, and the rest — and then
the `mret` in the privilege-drop trampoline jumped to PC `0` in user mode
instead of to the S-mode kernel. Reading the CSRs at that `mret` showed `mepc`
and `mstatus` were still zero. The `csrw` instructions had executed but not
committed.

The write-enable for the CSR file is `csr_we = is_csr & in_exec & ~take_trap`.
Tracing it showed `take_trap` was **X** — unknown — on every `csrw`, which made
`csr_we` X, which meant the write neither definitely happened nor definitely
didn't. `take_trap` was X because `irq_pending` was X. And `irq_pending` was X
even at reset, with `mie`, `mip`, `mstatus`, and `priv` all reading a defined
zero. An interrupt-pending signal that is X while every input to it is zero is a
contradiction — unless the logic computing it isn't actually watching those
inputs.

It wasn't. The per-source interrupt evaluation had been written as a Verilog
`function fire(idx, delegable)` called from six continuous assignments with
constant arguments: `wire f_ssi = fire(1, 1'b1);` and so on. In Icarus, a
continuous assignment that calls a function is made sensitive to the function's
*arguments*, not to the signals the function reads out of the surrounding module.
With constant arguments, nothing in the sensitivity list ever changes, so the
function is evaluated exactly once — at time zero, when `mie` and the rest are
still X — and the result is latched forever. Every `f_*` wire was frozen at its
time-zero X.

The fix is to not hide state reads inside a function behind constant arguments.
The six sources are now plain combinational expressions that name `mie`, `mip`,
`mideleg`, `mstatus`, and `priv` directly, so the assignments are sensitive to
the CSR state and re-evaluate when it changes. With `irq_pending` defined,
`take_trap` is defined, `csr_we` is clean, the setup writes commit, and the
`mret` drops correctly into S-mode. The lesson is a general one for simulation:
a signal stuck at X whose inputs are all defined is almost always a sensitivity
problem, not a logic problem.

## What the demo shows

`make smode` boots in machine mode. `main` delegates the user `ecall` (cause 8)
and illegal-instruction (cause 2) exceptions to S via `medeleg`, delegates the
supervisor software interrupt (cause 1) via `mideleg`, installs both trap
vectors, enables the supervisor software interrupt, and `mret`s into an S-mode
kernel. The kernel enables its own interrupts, issues one `ecall` — which is
cause 9, *not* delegated, so it lands in the machine handler, the deliberate
contrast — and then `sret`s down into a user task.

The user task first executes one illegal instruction, which is delegated
straight to the supervisor handler (cause 2). Then it loops: each pass issues an
`ecall` that the supervisor handler services, and on each service the handler
pends a supervisor software interrupt. The instant the handler returns to user
mode that interrupt fires — user mode is below supervisor, so it is delivered
regardless of `SIE` — and is taken to the supervisor handler again as cause 1,
which clears it and returns. After eight `ecall`s the kernel writes the SYSCON
halt register.

The counts close arithmetically. Eight user `ecall`s reach S; the illegal
instruction reaches S once; the single S-mode `ecall` reaches M once. The
software interrupt count is seven, one fewer than the `ecall` count, because the
eighth `ecall` halts the machine before its pended interrupt can be delivered.
Crucially, the machine handler's "saw a delegated cause" cell stays zero: causes
8, 2, and 1 never touched machine mode.

## What's verified here

The testbench reads the result cells the handlers write and asserts: the
user-`ecall`-to-S count is 8, the software-interrupt-to-S count is 7, the
illegal-to-S count is 1, the S-`ecall`-to-M count is 1, the user task made eight
visible progress increments, and eight dots were observed on the UART. Two cells
must be exactly zero: `m_bad`, which the machine handler writes only if it ever
sees a cause that should have been delegated, and `s_other`, which the
supervisor handler writes on any unexpected cause. A delegation bug in either
direction — a delegated trap leaking to M, or a non-delegated one diverted to S
— fails the run.

## Honest status

- Verified in simulation only.
- This core (`cpu_mc_s`) has no MMU, so delegation is demonstrated with `ecall`,
  illegal-instruction, and a software interrupt rather than page faults. The
  routing is cause-generic: the same `medeleg` path would deliver the MMU core's
  load/store page-fault causes (13/15) to an S-mode kernel unchanged. Folding
  delegation into `cpu_mc_mmu` so an S-mode kernel handles faults for user
  processes is the natural next step — and the shape xv6 expects.
- `sstatus`/`sie`/`sip` are simplified masked views. `SUM`, `MXR`, `UBE`, and
  the `vsstatus`/hypervisor fields do not exist; there is no `scounteren`.
- There is no supervisor *timer* hardware (no Sstc extension). The supervisor
  software interrupt is pended by a CSR write, which is enough to exercise
  `mideleg`. A real timer tick would arrive as the machine timer interrupt and
  be forwarded to S by the machine handler setting `STIP`.
- `mideleg` moves only the supervisor-level interrupts (causes 1/5/9); the
  machine-level interrupts are not delegatable, per the spec.
- Single-hart, direct-mode vectors only (no vectored `mtvec`/`stvec`).

## Takeaway

Delegation is what lets a kernel live one rung below the firmware without paying
for it. The hardware reads two bit-masks and routes the common traps — system
calls, faults, the preemption tick — straight to supervisor mode, reserving
machine mode for the genuine machine-level events that an operating system
should almost never have to think about. The system call that used to cost a
trip through the monitor now costs a direct jump to the kernel; the monitor
underneath only wakes for what is truly its job.
