# Step 10 (bonus) — Writing in C and running it on the CPU

Short answer: **yes**, and you just need a little glue. Your CPU executes RV32I
machine code, and a C compiler targeting RV32I produces exactly that. The only
gap is that C assumes a *runtime environment* — at minimum a stack and an entry
point — which a bare-metal core doesn't provide until you set it up.

Files:
- `sw/sum.c` — the C program
- `sw/crt0.s` — the startup routine ("C runtime zero")
- `sw/link.ld` — the linker script
- `sw/cbuild.sh` — compile → hex in one command
- `tb/c_tb.v` — runs the compiled program

## Why C needs scaffolding here

On a PC, when you run a program the operating system has already: loaded it,
set up a stack, zeroed `.bss`, and jumped to a startup routine that eventually
calls `main`. Our CPU has none of that. At reset:

- `PC = 0`, so whatever sits at address 0 runs first.
- All registers are 0 — including the stack pointer `sp`. A C function that
  pushes anything (saved registers, locals, a return address) would write to
  address 0 and below, which is garbage.

So we supply the two essentials ourselves: a **startup routine** at address 0
that sets up a stack and calls `main`, and a **linker script** that places that
routine first.

## The startup routine: `crt0.s`

```asm
        .section .text.init      # linker puts this first, at 0x0
        .globl _start
_start:
        li      sp, 0x1000       # stack pointer = top of data memory (4096)
        call    main             # run C; return value comes back in a0 (x10)
        sw      a0, 0(x0)        # publish the result at data memory address 0
halt:
        jal     x0, halt         # spin forever (no OS to return to)
```

Line by line:
- `li sp, 0x1000` — our data memory is 4096 bytes, and the RISC-V stack grows
  *downward*, so the stack pointer starts at the top (`0x1000`). The first push
  writes to `0xFFC`, safely in range.
- `call main` — a pseudo-instruction the assembler expands using instructions
  your CPU has. `main` leaves its `int` return value in register `a0` (`x10`),
  per the RISC-V calling convention.
- `sw a0, 0(x0)` — since there's no screen or `printf`, "output" means leaving
  the answer somewhere observable. We store it at data-memory address 0, which
  the testbench reads.
- `jal x0, halt` — a self-loop marks "done."

## The linker script: `link.ld`

```
ENTRY(_start)
SECTIONS {
    . = 0x00000000;
    .text   : { *(.text.init)   /* crt0 first */
                *(.text*) }
    .rodata : { *(.rodata*) }
    .data   : { *(.data*) }
    .bss    : { *(.bss*) *(COMMON) }
}
```

The one thing that *must* be true: `_start` is at address `0x0`, because that's
where the PC begins. Putting `.text.init` (where `crt0` lives) first in `.text`,
with the location counter starting at 0, guarantees it.

> **A note on initialized data.** This core's data memory powers up as zeros and
> has no mechanism to preload `.data`. So programs here should avoid relying on
> *initialized* globals (e.g. `int x = 5;` at file scope). Our program keeps all
> its data on the stack, so `.data`/`.bss` stay empty. Supporting initialized
> globals would mean adding a data-memory init file or a copy loop in `crt0` —
> a good extension exercise.

## The C program

```c
int sum_to(int n)
{
    int sum = 0;
    for (int i = 1; i <= n; i++)
        sum += i;
    return sum;
}

int main(void)
{
    return sum_to(10);   /* 55 */
}
```

It's deliberately a *function calling a function*, so the compiled code uses the
stack (saving the return address `ra` across the call) — proving the stack we
set up actually works.

## Compile to hex

`sw/cbuild.sh` runs the compiler with the right flags:

```bash
riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 \
    -nostdlib -nostartfiles -ffreestanding -O1 \
    -T sw/link.ld sw/crt0.s sw/sum.c -o build/cprog.elf
riscv64-unknown-elf-objcopy -O binary build/cprog.elf build/cprog.bin
python3 sw/bin2hex.py build/cprog.bin > sw/cprog.hex
```

The important flags:
- `-march=rv32i -mabi=ilp32` — generate only base 32-bit integer instructions,
  exactly what the CPU implements. (Without this, the compiler might emit
  `mul`/`div`, which are the "M" extension we didn't build.)
- `-nostdlib -nostartfiles -ffreestanding` — don't link the standard library or
  the default startup; we provide our own `crt0` and assume no OS.

Install the compiler once with:
```bash
sudo apt-get install -y gcc-riscv64-unknown-elf
```

### What the compiler produced

`objdump -d` shows clean RV32I — every instruction is one we built:

```
00000000 <_start>:
   0: lui  sp,0x1            # sp = 0x1000
   4: jal  38 <main>
   8: sw   a0,0(zero)        # store result to mem[0]
   c: j    c <halt>
00000010 <sum_to>:
  10: blez a0,30             # bge zero,a0  -> our branch comparator
  ...
  20: add  a0,a0,a5          # the loop body
  28: bne  a5,a4,20
  2c: ret                    # jalr x0,0(ra)
00000038 <main>:
  38: addi sp,sp,-16         # allocate a stack frame
  3c: sw   ra,12(sp)         # save return address
  44: jal  10 <sum_to>
  48: lw   ra,12(sp)         # restore it
  50: ret
```

Notice `main` allocating a stack frame and saving/restoring `ra` around the
call — that's the calling convention in action, running on hardware you built.

## Run it

```bash
make cprog
```

Output:

```
Built sw/cprog.hex
a0/return value stored at mem[0] = 55
final pc = 0000000c (should sit at the halt loop)
ALL TESTS PASSED  (C program returned 55)
```

Your processor compiled and executed a C program — function call, stack frame,
loop and all — and produced the right answer.

## What works and what doesn't (on this minimal core)

**Works:** integer arithmetic and logic, loops, conditionals, function calls,
recursion (it's just more stack), pointers and arrays *as long as they live in
the stack/data region*, `lw`/`sw` access to data memory.

**Doesn't, without more work:**
- **`printf` / any I/O** — there's no console. Add a memory-mapped "output
  port" (a magic store address the testbench prints) if you want output.
- **Multiplication / division** (`*`, `/`, `%`) — these need the "M" extension
  we didn't implement; with `-march=rv32i` the compiler emits library calls
  (`__mulsi3`, ...) that you'd have to link in, or you avoid those operators.
- **Initialized globals** — see the linker-script note above.
- **`malloc`, file I/O, the C standard library** — all need an OS or a ported
  libc (e.g. newlib with syscall stubs). Out of scope for a teaching core.

These limits are exactly the line between a minimal teaching CPU and a "real"
one — and each is a concrete next project if you want to push further.

## Back to the main thread

This was a bonus. The nine core steps already gave you a complete, programmable
RV32I processor; this one showed that "programmable" extends all the way up to
a C compiler. From here, the extension ideas in Step 09 (memory-mapped output,
the M extension for multiply/divide, pipelining, synthesis) all build naturally
on what you have.
