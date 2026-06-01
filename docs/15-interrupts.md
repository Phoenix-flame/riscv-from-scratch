# Step 15 — Interrupts: CSRs, traps, and a timer ISR

Everything so far has been **polled** — software checks a status register in a
loop. Interrupts let a peripheral signal the CPU *asynchronously*: the hardware
drops whatever it's doing, jumps to a handler, and resumes afterward. This is
the mechanism behind preemptive multitasking and responsive I/O, and it's the
biggest single feature separating a teaching core from one that can run an RTOS.

New/changed files:
- `rtl/csr.v` — the machine-mode CSRs + trap controller (new)
- `rtl/cpu_core.v` — CSR-instruction decode + trap/`mret` redirection
- `rtl/timer.v` — now drives an `irq` line
- `rtl/soc.v`, `rtl/fpga_top.v` — route the timer IRQ to the core
- `sw/irq_demo.c` — a program whose work happens entirely in an ISR

## The three ingredients

**1. CSRs (Control/Status Registers).** Interrupts are configured through a
separate register space accessed by the *Zicsr* instructions. The machine-mode
registers we need:

| CSR | Addr | Purpose |
|-----|------|---------|
| `mstatus` | 0x300 | bit 3 `MIE` = global interrupt enable; bit 7 `MPIE` = previous MIE |
| `mie` | 0x304 | bit 7 `MTIE` = enable the machine *timer* interrupt |
| `mtvec` | 0x305 | address of the trap handler |
| `mepc` | 0x341 | PC saved when a trap is taken |
| `mcause` | 0x342 | why the trap happened |
| `mip` | 0x344 | bit 7 `MTIP` = timer interrupt pending (read-only) |

**2. Trap logic.** When an interrupt is enabled and pending, the core must, in
one step: not commit the current instruction, save its PC to `mepc`, record the
cause, disable interrupts, and jump to `mtvec`. The `mret` instruction reverses
this: restore the interrupt-enable and jump back to `mepc`.

**3. An interrupt source.** The timer raises a line when `mtime >= mtimecmp`.

## CSR instructions (Zicsr)

Six instructions, all opcode `SYSTEM` (`1110011`) with `funct3 != 0`:

| funct3 | name | effect (atomic read-then-modify) |
|--------|------|----------------------------------|
| 001 | `csrrw`  | rd = csr; csr = rs1 |
| 010 | `csrrs`  | rd = csr; csr |= rs1 |
| 011 | `csrrc`  | rd = csr; csr &= ~rs1 |
| 101 | `csrrwi` | like csrrw with a 5-bit immediate |
| 110 | `csrrsi` | like csrrs with immediate |
| 111 | `csrrci` | like csrrc with immediate |

`csr.v` reads the addressed register combinationally (for `rd`) and, on the
clock edge, updates it with the read/set/clear value. `mret` (also `SYSTEM`,
`funct3=0`, `imm=0x302`) is decoded separately.

> **Toolchain note:** these instructions require enabling the extension:
> compile with `-march=rv32i_zicsr` (plain `rv32i` rejects them).

## How the core takes a trap

In `cpu_core.v` the decode adds:

```verilog
wire is_system = (opcode == 7'b1110011);
wire is_csr    = is_system && (funct3 != 3'b000);
wire is_mret   = is_system && (funct3 == 3'b000) && (instr[31:20] == 12'h302);
```

The trap decision is just: is an interrupt enabled *and* pending?

```verilog
// inside csr.v:
assign irq_pending = mstatus.MIE & mie.MTIE & timer_irq;
// inside cpu_core.v:
wire take_trap = irq_pending;
```

When `take_trap` is high, two things happen in the same cycle:

- **The current instruction is suppressed** so it doesn't commit — it will
  re-run after the handler returns:
  ```verilog
  wire reg_write_eff = take_trap ? 1'b0 : (is_csr ? 1'b1 : reg_write);
  wire mem_write_eff = take_trap ? 1'b0 : mem_write;
  ```
- **The PC is redirected** to the handler (trap and `mret` get top priority over
  jumps/branches):
  ```verilog
  if      (take_trap) next_pc = mtvec;     // enter handler
  else if (is_mret)   next_pc = mepc;      // return from handler
  else if (jalr)      ...
  ```

And `csr.v`, on that edge, saves the state:

```verilog
if (take_trap) begin
    mepc       <= pc;            // resume the interrupted instruction later
    mcause     <= 32'h8000_0007; // interrupt (bit 31) + code 7 (M-timer)
    mstatus[7] <= mstatus[3];    // MPIE <- MIE
    mstatus[3] <= 1'b0;          // MIE  <- 0  (no nested IRQ during the ISR)
end else if (is_mret) begin
    mstatus[3] <= mstatus[7];    // MIE  <- MPIE
    mstatus[7] <= 1'b1;
end
```

Because `MIE` is cleared on entry, the handler runs with interrupts off (no
re-entry) until `mret` restores it. The handler also writes a fresh `mtimecmp`,
which deasserts `timer_irq` so the same interrupt doesn't immediately fire
again.

## Why `mepc = pc` (not `pc+4`)

For an asynchronous interrupt, the current instruction *hasn't executed yet* —
we suppressed it. So we save its own address and re-run it after the handler.
(Synchronous exceptions like `ecall` differ — there `mepc` is the faulting
instruction and software advances past it — but we only implement timer
interrupts here.)

## The program: work that happens in an ISR

`sw/irq_demo.c`:

```c
volatile unsigned ticks = 0;

__attribute__((interrupt("machine")))   /* GCC emits save/restore + mret */
void mtimer_isr(void) {
    ticks++;
    MTIMECMP = MTIME + INTERVAL;         /* rearm -> deasserts the IRQ */
}

int main(void) {
    asm volatile("csrw mtvec, %0" :: "r"((unsigned)&mtimer_isr));
    MTIMECMP = MTIME + INTERVAL;
    asm volatile("li t0,0x80; csrs mie, t0" ::: "t0");  /* MTIE */
    asm volatile("csrsi mstatus, 0x8");                 /* MIE  */
    while (ticks < 5u) { }     /* just spin -- the ISR runs in the background */
    kprintf("main: observed %u timer interrupts\n", ticks);
    halt(0);
}
```

The `__attribute__((interrupt("machine")))` is what makes a plain C function a
valid handler: GCC generates the register save/restore prologue/epilogue and
terminates it with `mret` instead of `ret`. We only have to point `mtvec` at it
and enable the interrupt.

Note `main` **never calls** `mtimer_isr`. The only thing incrementing `ticks`
is the hardware delivering interrupts while `main` spins.

## Run it

```bash
make irq
```

```
---- UART output ----
main: enabling timer interrupts...
main: observed 5 timer interrupts
[syscon] halt requested, exit code = 0
final ticks stored in RAM = 9
```

Two things worth noticing:

- `main` printed "5" the instant its `while (ticks < 5)` loop exited.
- The final stored count is **9** — the ISR kept firing during the (slow)
  `kprintf` and the store that followed. That divergence is the visible proof
  that the ISR runs *asynchronously*, preempting `main` rather than being called
  by it.

## What this enables, and what's still missing

With interrupts you can build a periodic tick (the basis of an RTOS scheduler),
responsive UART RX, and event-driven I/O instead of busy-polling.

Still not implemented (natural extensions):

- **Synchronous exceptions** — `ecall` (system call), illegal-instruction and
  misaligned traps. Same trap machinery, different `mcause` and an `mepc`
  advance in software.
- **Vectored `mtvec`** — we use direct mode (all traps to one address); vectored
  mode jumps per-cause.
- **Nested/prioritized interrupts**, an external-interrupt controller (PLIC),
  and multiple sources beyond the timer.
- **Privilege modes** (user vs machine) — we run entirely in machine mode.

But the core mechanism — CSRs, trap entry/exit, an asynchronous source — is now
real and verified. Your processor can respond to the outside world on its own
schedule.
