# Step 21 — Privilege levels: machine mode and user mode

So far every instruction has run with full power over the machine — any code can
read CSRs, set `mtvec`, execute `mret`. That's fine for firmware, but it's not
how a real system works: an operating system runs privileged, applications run
*unprivileged*, and the hardware enforces the wall between them. This step adds
that wall — a second privilege level, **user mode (U)**, below **machine mode
(M)** — and turns the Step-19 `ecall` ABI into a genuine user/kernel boundary.

## The idea

RISC-V defines privilege levels; we implement two: **M (machine)** and **U
(user)**. The CPU tracks a current privilege in a `priv` register (reset to M).
The rules:

- **Traps always raise privilege to M.** Whatever mode you were in, a trap
  enters the M-mode handler. The previous privilege is saved in `mstatus.MPP`.
- **`mret` restores the saved privilege.** Returning from a trap drops back to
  `MPP` — so an M-mode handler can `mret` *down* into user mode.
- **User mode can't touch privileged state.** Executing `mret` or any CSR
  instruction from U-mode is an **illegal instruction** (it traps). This is the
  protection: applications physically cannot reconfigure the machine.
- **`ecall` reports where it came from.** An `ecall` from U-mode raises cause 8;
  from M-mode, cause 11. The handler uses the cause to tell a user syscall from
  a firmware call.

## Hardware changes

In `csr.v`, a `priv` register plus `mstatus.MPP` (bits [12:11]) capture and
restore the privilege across a trap:

```verilog
// on trap entry:
mstatus[12:11] <= priv;        // MPP <- where we came from
priv           <= PRIV_M;      // traps run in machine mode
// on mret:
priv           <= mstatus[12:11];   // restore saved privilege
mstatus[12:11] <= PRIV_U;           // MPP <- least privilege
```

In `cpu_core.v`, the privilege check makes user-mode access to privileged state
illegal, and `ecall`'s cause becomes mode-dependent:

```verilog
wire in_user        = (cur_priv == 2'b00);
wire priv_violation = in_user & (is_mret | is_csr);   // U-mode can't do these
wire illegal_instr  = ~op_known | priv_violation;

wire [31:0] trap_cause = illegal_instr ? 2 :
                         is_ecall       ? (in_user ? 8 : 11) :  // U vs M ecall
                         is_ebreak      ? 3 : 32'h8000_0007;
```

That's the whole mechanism: one privilege bit, captured/restored through `MPP`,
and a check that turns privileged instructions into faults when unprivileged.

## Software: dropping into user mode

There's no instruction that says "go to user mode" directly — you get there by
*returning* there. The kernel sets `mstatus.MPP = U`, points `mepc` at the user
entry, and executes `mret`:

```c
static void enter_user(void (*entry)(void)) {
    unsigned ms;
    asm volatile ("csrr %0, mstatus" : "=r"(ms));
    ms &= ~(3u << 11);                         /* MPP = U */
    asm volatile ("csrw mstatus, %0" :: "r"(ms));
    asm volatile ("csrw mepc, %0"   :: "r"(entry));
    asm volatile ("mret");                      /* -> user mode at entry */
}
```

After the `mret`, the CPU is in user mode running `entry`. From there the only
way back up to machine mode is a trap — exactly the controlled entry point we
want.

## The demo

`sw/priv_demo.c` (kernel, M-mode) installs the handler, prints a line, and drops
to `user_main`. `user_main` (U-mode) prints via `ecall` syscalls, then
deliberately executes a privileged `csrr` to prove it gets blocked. `sw/ptrap.S`
is the M-mode handler: cause 8 → service the syscall, cause 2 → report the
blocked instruction and skip it.

```bash
make priv
```

```
kernel: configured trap vector, dropping to user mode
user: hello from U-mode (printed via ecall syscalls)
user: now trying a privileged CSR read...
kernel: blocked a privileged instruction from user mode!
user: survived (kernel skipped the blocked op), exiting
```

Three things are happening here, all enforced by hardware:

1. The kernel runs privileged, then `mret`s *down* into user mode.
2. User code reaches the kernel only through `ecall` (cause 8) — a single,
   controlled entry point with an agreed ABI (number in `a7`, arg in `a0`).
3. When user code tries `csrr mstatus`, the hardware raises an illegal-
   instruction trap instead of executing it. The kernel catches it, prints a
   notice, skips it, and returns. **The application could not reconfigure the
   machine even though it tried.**

## What's still missing for a real OS

- **Memory protection.** We protect privileged *instructions*, but not *memory*:
  there's no PMP/MMU, so user code can still store to MMIO or any RAM address
  directly. A real system adds physical memory protection (PMP) or virtual
  memory (page tables) so user code is confined to its own memory and *must* use
  syscalls for I/O. That's the natural next step.
- **Supervisor mode (S)** and the full trap-delegation machinery (`medeleg`,
  `mideleg`) for a three-level OS/hypervisor stack.
- **Per-process state**, timers for preemptive scheduling (we have the timer
  interrupt from Step 15 — combine it with user mode and you can preempt a user
  program), and context switching.

But the essential hardware wall — privileged vs unprivileged, with traps as the
one-way door up and `mret` as the door down — is now real and enforced.

## Takeaway

A privilege level is astonishingly little hardware: one state bit, saved and
restored through `mstatus.MPP`, plus a rule that privileged instructions fault
when you're unprivileged. From that tiny mechanism the entire user/kernel
model follows — controlled entry via `ecall`, protected configuration, and a
kernel that can hand the CPU to an application and always get it back.
