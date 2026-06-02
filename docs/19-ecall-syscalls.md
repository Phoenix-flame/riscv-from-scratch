# Step 19 — System calls with `ecall`

`ecall` ("environment call") is how user code asks a more privileged layer to
do something for it — the RISC-V equivalent of a syscall trap on a real OS. This
step builds a tiny syscall ABI on the single-cycle core: user code puts a
syscall number in `a7` and an argument in `a0`, executes `ecall`, and a
machine-mode handler services the request.

This reuses the trap machinery from Steps 15/18 — `ecall` is just another
synchronous exception, with `mcause = 11` (environment call from M-mode).

## Hardware: `ecall` as an exception

`ecall` is the SYSTEM opcode with `funct3=0` and `imm=0`. `cpu_core.v` already
decodes SYSTEM for CSRs and `mret`; we add `ecall`/`ebreak` detection and fold
them into the trap condition:

```verilog
wire is_ecall  = is_system && funct3==0 && instr[31:20]==12'h000;
wire is_ebreak = is_system && funct3==0 && instr[31:20]==12'h001;
wire exception = illegal_instr | is_ecall | is_ebreak;     // unmaskable
wire take_trap = exception | irq_pending;
wire [31:0] trap_cause = illegal_instr ? 2 : is_ecall ? 11 : is_ebreak ? 3
                                                            : 32'h8000_0007;
```

On the trap, `mepc` captures the address of the `ecall` itself. That's
deliberate: the handler decides whether to retry or skip it. For a syscall we
**skip** it by advancing `mepc` by 4 before returning, so `mret` resumes at the
instruction *after* the `ecall`.

## Software: the syscall ABI

`sw/trap_handler.S` is the kernel side. It reads `mcause`, and for an `ecall`
dispatches on `a7`:

```asm
trap_entry:
    csrr t0, mcause
    li   t1, 11             # ecall from M-mode?
    bne  t0, t1, trap_done
    li   t1, 1              # a7 == 1  -> SYS_PUTC
    beq  a7, t1, sys_putc
    li   t1, 2              # a7 == 2  -> SYS_EXIT
    beq  a7, t1, sys_exit
trap_done:
    csrr t0, mepc           # skip past the ecall (4 bytes) ...
    addi t0, t0, 4
    csrw mepc, t0
    mret                    # ... and resume there
```

`SYS_PUTC` stores `a0` to the UART; `SYS_EXIT` stores `a0` to the SYSCON
(halting the sim). The handler preserves the temporaries it uses on the stack so
the interrupted code is undisturbed — `a0`/`a7` are read directly since they
still hold the caller's values when the trap is taken.

The user side wraps `ecall` in a small inline-asm helper:

```c
static inline long syscall1(long num, long arg) {
    register long a0 asm("a0") = arg;
    register long a7 asm("a7") = num;
    asm volatile ("ecall" : "+r"(a0) : "r"(a7) : "memory");
    return a0;
}
```

`sw/ecall_demo.c` installs the vector (`csrw mtvec, &trap_entry`) and prints a
string one character at a time through `SYS_PUTC`, then calls `SYS_EXIT`.

## Run it

```bash
make ecall
```

```
hello via ecall syscalls!
[syscon] halt requested, exit code = 0
```

Every character took the full round trip: user code → `ecall` (trap) → handler
dispatch on `a7` → UART store → `mret` back to the loop. The program even
*halts* via a syscall rather than touching the SYSCON directly.

## Why this matters

This is the exact mechanism a real OS uses for the user/kernel boundary: a
controlled, single entry point (`mtvec`) that switches privilege, with arguments
passed in registers by an agreed ABI. Here both sides run in machine mode so
there's no isolation yet, but the structure — trap in, dispatch on a number,
service, return — is the real thing. Add user mode (the `U` privilege level) and
page-based memory protection and you'd have the bones of a kernel.

## Next

`docs/20-pipelined-exceptions.md` — making all of this (interrupts, `ecall`,
illegal-instruction) work in the 5-stage **pipeline**, where being *precise*
about which instruction trapped is the whole challenge.
