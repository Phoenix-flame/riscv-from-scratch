# Step 18 — How the assembler knows the ISA, and trapping illegal instructions

This step answers a common question — *how does the assembler know which
instructions my CPU implements?* — and then closes the gap it exposes by making
the hardware **fault** on instructions it doesn't implement, instead of
silently ignoring them.

## FAQ: the assembler doesn't know your hardware exists

It's natural to assume the toolchain somehow inspects your design. It does not.
There is **no connection** between the assembler and your Verilog.

What the assembler actually uses:

- A built-in table of the **entire RISC-V ISA**, organized by extension.
- The **`-march`** string *you* pass, which selects which extensions are legal.

So `-march` is a *declaration you make*, not something discovered:

- `-march=rv32i` — only base integer ops are allowed. `a * b` can't become
  `mul`; the compiler emits a **call to a software routine** instead.
- `-march=rv32im` — the `m` makes multiply/divide legal, so `a * b` compiles to
  a single `mul` instruction.
- `-march=rv32i_zicsr` — required before `csrw`/`csrr` are even accepted (you
  saw this exact gate while building interrupts).

The encoding is universal: `mul` is `0x02b50533` no matter what will run it. The
assembler just looks the mnemonic up in its table and emits the standard bits.

### The two sides are matched only by you

Your CPU's entire knowledge of the instruction set is `control.v` + `alu.v`.
There's no feedback path from the hardware to the assembler:

```
RISC-V spec ─▶ assembler (gated by -march) ─▶ machine code
                                                   │   (no feedback)
                                                   ▼
                       your control.v / alu.v ─▶ executes, or...?
```

Before this step, any opcode the control unit didn't decode fell into its
`default:` case — all control signals zero, i.e. a **silent NOP**. The
assembler would happily encode a valid-RV32I instruction your hardware ignores
(e.g. `fence`, `ecall`), and nothing anywhere would complain. Worse, if you
assembled for `rv32im` but had forgotten to implement `mul`, the program would
build with no warning and compute garbage at runtime.

That silent failure is the gap. A real chip closes it from the hardware side:
it raises an **illegal-instruction exception** for anything it can't decode.

## Implementation: fault instead of NOP

We already have the trap machinery from Step 15 (CSRs, `mtvec`, `mepc`,
`mcause`, `mret`). An illegal instruction is just another trap — a *synchronous
exception* rather than an asynchronous interrupt.

### 1. Detect the unknown opcode (`cpu_core.v`)

```verilog
wire op_known =
    (opcode==7'b0110011) || (opcode==7'b0010011) || (opcode==7'b0000011) ||
    (opcode==7'b0100011) || (opcode==7'b1100011) || (opcode==7'b1101111) ||
    (opcode==7'b1100111) || (opcode==7'b0110111) || (opcode==7'b0010111) ||
    (opcode==7'b1110011) || (opcode==7'b0001111);   // + SYSTEM + FENCE
wire illegal_instr = ~op_known;
```

`SYSTEM` (CSR/`mret`/`ecall`) and `FENCE` are treated as legal — `FENCE` is a
defined no-op on a simple in-order core, so faulting on it would be wrong.

### 2. Make it trap — unconditionally

Interrupts are *maskable* (gated by `mstatus.MIE`); an illegal-instruction
exception is **not** — it must always trap:

```verilog
wire take_trap = illegal_instr | irq_pending;   // exception OR interrupt
```

When `take_trap` is high, the existing logic already suppresses the
instruction's writes and redirects the PC to `mtvec`. We only add the cause:

```verilog
// in csr.v, on trap entry:
mcause <= is_illegal ? 32'd2 : 32'h8000_0007;  // 2 = illegal instr; 7 = M timer
mepc   <= pc;                                   // the faulting instruction
```

`mcause = 2` is the RISC-V code for "illegal instruction." Because exceptions
aren't masked, this fires even with interrupts disabled.

## Demonstration

`sw/illegal_demo.c` points `mtvec` at a handler and then deliberately executes a
word the hardware doesn't decode:

```c
__attribute__((interrupt("machine")))
void trap_handler(void) {
    unsigned cause, epc;
    asm volatile ("csrr %0, mcause" : "=r"(cause));
    asm volatile ("csrr %0, mepc"   : "=r"(epc));
    kprintf("TRAP! mcause=%u (2 = illegal instruction)  mepc=0x%x\n", cause, epc);
    halt(0);
}

int main(void) {
    asm volatile ("csrw mtvec, %0" :: "r"((unsigned)&trap_handler));
    kprintf("about to execute an undecoded instruction...\n");
    asm volatile (".word 0x0000000b");   /* custom-0 opcode: not implemented */
    kprintf("THIS LINE SHOULD NOT PRINT\n");
    halt(1);
}
```

`.word 0x0000000b` plants a raw 32-bit value with an opcode our decoder doesn't
recognize. Run it:

```bash
make illegal
```

```
about to execute an undecoded instruction...
TRAP! mcause=2 (2 = illegal instruction)  mepc=0x88
[syscon] halt requested, exit code = 0
```

The faulting instruction lived at `0x88`, exactly what `mepc` reports, the cause
is `2`, and the line after the bad instruction **never printed** — the hardware
faulted instead of NOP-ing, and the handler caught it. Before this step that
same word would have slipped through as a silent NOP and execution would have
continued into the line that "should not print."

## Notes and further steps

- **Granularity.** We detect illegal opcodes. Stricter decoding could also fault
  on reserved `funct3`/`funct7` combinations within a known opcode; that's more
  cases but the same mechanism.
- **`misa` and friends.** A full core also exposes the `misa` CSR so software
  can *query* which extensions exist, rather than discovering them by trapping.
- **Other synchronous exceptions** — `ecall` (system call), breakpoints, and
  load/store address-misaligned — all reuse this exact path with different
  `mcause` codes and (for `ecall`) an `mepc + 4` advance in software.
- **The pipelined core** (`cpu_pipe.v`) doesn't have this — it's RV32IM with no
  CSRs. Precise exceptions in a pipeline are the harder, and very worthwhile,
  follow-on.

## Takeaway

The assembler validates against the ISA you *declare* with `-march`; your
hardware decodes the subset you *built*. Keeping them in agreement is on you —
and an illegal-instruction trap is how the hardware enforces its half of the
contract, turning a silent wrong-answer bug into a clean, diagnosable fault.
