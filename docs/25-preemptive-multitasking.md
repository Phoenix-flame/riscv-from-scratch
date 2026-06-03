# Step 25 — Preemptive multitasking: a timer-driven scheduler

Everything needed for multitasking was already on the chip — a timer that
raises an interrupt, traps that switch to machine mode, and user/machine
privilege. This step puts them together into the smallest thing that
honestly deserves the word *kernel*: two user tasks that **never cooperate**,
forced to take turns by a timer interrupt.

The output says it all:

```
AAAAbbbbAAAAbbbbAAAAbbbbAAAAbbb...
```

Task A only ever prints `A` (in an infinite loop), task B only prints `b`.
Neither calls the other or yields. The fact that they interleave means
something is reaching in from outside and switching them — preemption.

## What "preemptive" means here

A *cooperative* scheduler relies on tasks politely calling `yield()`. A
*preemptive* one doesn't trust them: a periodic timer interrupt stops whatever
is running, no matter where it is, and the kernel decides who runs next. Our
tasks are deliberately rude — tight `for(;;)` loops — precisely to show they get
switched anyway.

## The mechanism: a context switch

Each task has a **context**: a 32-word block holding its saved registers plus
where it was executing (`mepc`). `ctx0` is task A, `ctx1` is task B. The CSR
`mscratch` always points at the *currently running* task's context.

When the timer fires, the hardware traps to machine mode at `mtvec` (our
`trap_entry`) with interrupts disabled. The handler, in assembly because it must
touch every register without clobbering them:

1. `csrrw sp, mscratch, sp` — the classic trap-entry swap. Now `sp` points at the
   current task's context and the task's real `sp` is parked in `mscratch`.
2. Save `x1`, `x3`–`x31` into the context, then recover the task's `sp` from
   `mscratch` and save it too, then save `mepc`. The task is now frozen in memory.
3. Bookkeeping: bump a tick counter (and halt after a fixed number so the demo
   ends), and program the next tick with `mtimecmp = mtime + INTERVAL`. This also
   de-asserts the (level-sensitive) timer interrupt.
4. Schedule: flip `cur`, point `sp` at the other context.
5. Set `mscratch` to the new context (ready for *its* next trap), reload `mepc`
   and every register from it, and restore the new task's `sp` **last** — because
   that instruction overwrites the base pointer we were reading through.
6. `mret` — privilege drops back to user and execution resumes in the other task
   exactly where it left off. It has no idea anything happened.

The trickiest details are ordering: the base register (`sp`) and the scratch
register used to reload `mepc` must be restored after they're no longer needed as
pointers, or you'd saw off the branch you're sitting on.

## Launching the first task

There's a chicken-and-egg problem: the scheduler resumes tasks, but who starts
the first one? The kernel (`main`, in C) builds both contexts by hand — each gets
its task's entry address as `mepc` and its own stack — points `mscratch` at task
A, installs `mtvec`, enables the timer interrupt (`mie.MTIE`), arms the first
tick, and then calls `launch()`. `launch` sets `mstatus.MPP = User` and
`mstatus.MPIE = 1` (so interrupts are on after the return), loads task A's `pc`
and `sp`, and `mret`s into it. From then on the timer drives everything.

## Things worth noticing

- **Two stacks, one address space.** Each task gets its own stack region; there's
  no MMU here, so they share everything else. That's fine for a demo but means a
  buggy task can stomp the other — exactly the problem virtual memory (Steps 22 /
  24) exists to solve. Combining this scheduler with a per-task `satp` is the path
  to real *process* isolation.
- **The tasks run in user mode.** They can't touch CSRs or `mret` (those trap as
  illegal), so only the kernel can drive the machine. They reach the UART directly
  only because this core has no memory protection.
- **Quantum size is a knob.** `INTERVAL` controls how long each task runs per
  turn. Larger means longer bursts (`AAAAAAAA bbbbbbbb`), smaller means finer
  interleaving (`AbAbAb`). It's the same trade-off a real OS tunes between
  throughput and responsiveness.

## Build and run

```
make sched
```

## Where this points next

This is the scheduler half of an operating system. The memory half is in the MMU
steps. Bring them together — give each task its own page table and switch `satp`
in the context switch — and you have genuinely isolated processes. Add
supervisor mode and you have the privilege structure a real kernel uses. That
combination, plus the `A` (atomic) extension for locks, is the doorway to running
an existing OS instead of a bespoke one.

## Takeaway

A preemptive scheduler is, mechanically, just a trap handler that saves one
register set and restores another. Everything that makes multitasking *feel*
like magic — programs that don't know they're sharing a CPU — comes from that one
disciplined save/restore plus a timer that won't stop ticking.
