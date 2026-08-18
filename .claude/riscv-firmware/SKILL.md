---
name: riscv-firmware
description: >
  Use this skill whenever the user needs to write or debug bare-metal C firmware
  for the RISC-V CPU tutorial project. Triggers on: writing a new .c demo/test
  program for the CPU, debugging firmware that isn't behaving as expected in
  simulation, asking how to set up an ISR (interrupt service routine), configuring
  CSRs (mtvec, mie, mstatus), communicating results to a testbench via fixed RAM
  addresses, calling SYSCON to halt the core, writing an ecall handler, or
  any question about what gcc emits for a given C construct on rv32i/rv32im/rv32imc.
---

# RISC-V Bare-Metal Firmware Skill

This project runs firmware on a simulated RV32IM(C) core with no OS, no libc,
no dynamic allocation, and no gdb. The entire runtime is `sw/crt0.s` plus what
you write.

## Build command

```bash
riscv64-unknown-elf-gcc \
  -march=rv32i[m][c][_zicsr] \
  -mabi=ilp32 \
  -nostdlib -nostartfiles -ffreestanding \
  -O1 \
  -T sw/link.ld \
  sw/crt0.s sw/your_prog.c \
  -o build/your_prog.elf \
  -lgcc            # needed for __mulsi3, __divsi3 etc if using M extension
```

Choose `-march` based on what the core under test supports:
- Plain single-cycle or pipeline: `rv32i`
- M extension (mul/div): `rv32im`
- With CSR instructions: add `_zicsr` (e.g. `rv32im_zicsr`)
- With C extension: `rv32imc` or `rv32imc_zicsr`

## What crt0.s does (and doesn't)

```asm
_start:
    li sp, 0x1000       # stack pointer; RAM is 0x0000–0x3FFF typically
    call main
    sw a0, 0(x0)        # store exit code at address 0
halt: j halt            # spin forever
```

**BSS is NOT zeroed.** Initialise every global/static variable in `main` before
reading it. Pattern:
```c
volatile unsigned my_count;   // declared but NOT zero at reset
// in main():
my_count = 0;                 // must do this explicitly
```

## Testbench handshake pattern

Firmware communicates results to the Verilog testbench through fixed RAM addresses.
Use `volatile` for everything the testbench watches — the compiler must not
optimise these away.

```c
#define M(a)   (*(volatile unsigned *)(a))

// typical layout
#define READY  M(0x800)    // firmware sets 1 when configured; tb waits on this
#define RESULT M(0x804)    // output values, phase results
#define DONE   M(0x808)    // set to 0x600D when all done; tb checks this

// halt the core
#define SYSCON 0x20000000u
M(SYSCON) = 1;             // write anything to halt
for (;;) { }               // unreachable, but keeps the compiler happy
```

In the testbench, `rd(0x808) == 32'h0000_600D` is the canonical "done" check.
Use phase handshakes (`READY`, `P1DONE`, `P2READY`) for multi-phase tests.

## Memory map

```
0x0000_0000  RAM (data, stack, BSS)
0x1000_0000  UART
0x1001_0000  CLINT (mtimecmp at +0x4000, mtime at +0xBFF8)
0x1002_0000  PLIC  (see RTL skill for register map)
0x2000_0000  SYSCON (write -> halt)
```

Stack grows down from `sp = 0x1000`. Keep globals low (< 0x400 for small demos).

## Interrupt / CSR setup

```c
// 1. Write the handler — compiler generates save/restore + mret
void __attribute__((interrupt("machine"), aligned(4))) trap_handler(void) {
    // read mcause, mepc if needed
    unsigned cause, epc;
    __asm__ volatile("csrr %0, mcause" : "=r"(cause));
    __asm__ volatile("csrr %0, mepc"  : "=r"(epc));

    // for ecall: advance past the instruction
    if ((cause & 0xff) == 8 || (cause & 0xff) == 11)
        __asm__ volatile("csrw mepc, %0" :: "r"(epc + 4));

    // clear the peripheral interrupt (e.g. PLIC claim)
    // CLAIM = CLAIM;  // read-to-claim, write-to-complete
}

// 2. Wire it up in main
void main(void) {
    __asm__ volatile("csrw mtvec, %0"    :: "r"((unsigned)&trap_handler));
    __asm__ volatile("csrs mie,    %0"   :: "r"(1u << 11));  // MEIE (ext)
    __asm__ volatile("csrs mie,    %0"   :: "r"(1u << 7));   // MTIE (timer)
    __asm__ volatile("csrs mstatus,%0"   :: "r"(1u << 3));   // MIE (global)
    ...
}
```

`mtvec` must be 4-byte aligned. `__attribute__((aligned(4)))` on the handler
ensures this. Use `__attribute__((interrupt("machine")))` — NOT `__attribute__((naked))`.

**mie bit positions:**
- bit 3: MSIE (software interrupt enable) — rarely used
- bit 7: MTIE (timer)
- bit 11: MEIE (external / PLIC)

## PLIC from firmware

```c
#define PLIC        0x10020000u
#define PRIO(i)     (*(volatile unsigned *)(PLIC + 4u*(i)))
#define PENDING     (*(volatile unsigned *)(PLIC + 0x1000))
#define ENABLE      (*(volatile unsigned *)(PLIC + 0x2000))
#define THRESH      (*(volatile unsigned *)(PLIC + 0x3000))
#define CLAIM       (*(volatile unsigned *)(PLIC + 0x3004))

// Setup (in main before enabling MIE):
PRIO(1) = 2;  PRIO(2) = 5;  // source 1 priority=2, source 2 priority=5
ENABLE  = (1u<<1) | (1u<<2); // enable sources 1 and 2
THRESH  = 0;                  // admit everything above 0

// ISR drain loop — claim returns 0 when no more pending:
void trap_handler(void) {
    unsigned id;
    while ((id = CLAIM) != 0u) {
        // service device id
        CLAIM = id;   // complete
    }
}
```

## CLINT timer

```c
#define CLINT       0x10010000u
#define MTIMECMP    (*(volatile unsigned long long *)(CLINT + 0x4000))
#define MTIME       (*(volatile unsigned long long *)(CLINT + 0xBFF8))

// One-shot: fire in N cycles
MTIMECMP = MTIME + N;

// In timer ISR: re-arm for next period
void trap_handler(void) {
    MTIMECMP = MTIME + PERIOD;
}
```

## UART

```c
#define UART        0x10000000u
#define UART_TX     (*(volatile unsigned *)(UART + 0))
#define UART_STATUS (*(volatile unsigned *)(UART + 8))
#define UART_TX_RDY (1u << 0)    // check before writing

void uart_putc(char c) {
    while (!(UART_STATUS & UART_TX_RDY)) { }
    UART_TX = c;
}
```

## Common firmware bugs in simulation

**Bug: reads wrong value from peripheral**
Cause: Missing `volatile`. The compiler caches the first read in a register.
Fix: Every pointer to a peripheral address must be `volatile unsigned *`.

**Bug: ISR fires but handler seems to do nothing**
Cause: `mtvec` set to an unaligned address, or not set at all.
Fix: `__attribute__((aligned(4)))` on handler; verify with `nm build/prog.elf`.

**Bug: ISR runs once then global interrupts disabled forever**
Cause: The generic interrupt entry only restores `mstatus.MIE` on `mret`. If
the handler itself calls `mret` via a naked function or asm, MPIE doesn't
propagate. Use `__attribute__((interrupt("machine")))` and let gcc do the
prologue/epilogue.

**Bug: ecall / trap increments PC by wrong amount**
Cause: With RVC, some instructions are 2 bytes, not 4. If using rv32imc, check
`mepc` before blindly adding 4. For ecall (which is always 4 bytes, never
compressed), `mepc + 4` is always correct. For `ebreak` or illegal-instruction
traps from compressed code, you'd need to inspect `mepc[0:1]` to determine
instruction length — but ecall is always safe.

**Bug: firmware hangs waiting on READY but testbench never sees it**
Cause: BSS not zeroed — `nclaim` or another counter starts non-zero and the
`while (nclaim < N)` condition is already true or never reached.
Fix: Explicitly zero every counter/flag in `main`.

**Bug: wrong value at result address**
Cause: Wrote to a byte address that bram_ram rounds to a different word, or
used byte/halfword stores and forgot alignment.
Fix: Stick to `unsigned` (32-bit) stores to 4-byte-aligned addresses in demos.

## Checking what gcc actually emits

Disassemble to verify instruction selection, especially for RVC:
```bash
riscv64-unknown-elf-objdump -d build/prog.elf
riscv64-unknown-elf-size build/prog.elf     # text/data/bss byte counts
riscv64-unknown-elf-nm   build/prog.elf     # symbol addresses
```

For RVC coverage, count 16-bit vs 32-bit instructions:
```bash
riscv64-unknown-elf-objdump -d build/prog.elf | awk '
/^\s*[0-9a-f]+:/ {n=length($2); if(n==4)c16++; if(n==8)c32++}
END {print c16 " compressed, " c32 " full-width"}'
```

To check for straddling 32-bit instructions (addr%4==2):
```bash
riscv64-unknown-elf-objdump -d build/prog.elf | python3 -c "
import sys, re
for line in sys.stdin:
    m=re.match(r'\s*([0-9a-f]+):\s+([0-9a-f]{8})\s',line)
    if m and int(m.group(1),16)%4==2: print('STRADDLE',line.strip())"
```
