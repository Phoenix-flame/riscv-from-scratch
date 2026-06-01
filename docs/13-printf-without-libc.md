# Step 13 — printf without a libc: a freestanding mini-library

Reaching for `#include <stdio.h>` (for `snprintf`) or `<string.h>` (for
`strlen`) fails on this setup:

```
fatal error: stdio.h: No such file or directory
fatal error: string.h: No such file or directory
```

This step explains why, and builds a small library that gives you `printf`,
`snprintf`, `strlen`, etc. — output going to your UART — without any host C
library.

Files:
- `sw/firmware.h`, `sw/firmware.c` — the mini-library
- `sw/soc_demo.c` — rewritten to use it

## Why the standard headers aren't there

The Ubuntu package `gcc-riscv64-unknown-elf` is a **compiler only**. It ships no
C library — no newlib, no `stdio.h`, no `libc.a`:

```bash
$ find / -name stdio.h -path '*riscv*'   # (nothing)
$ find / -name libc.a  -path '*riscv*'   # (nothing)
```

So `<stdio.h>`/`<string.h>` simply don't exist to include. And even with them,
two more problems remain on a bare-metal core:

1. **Linking.** We build with `-nostdlib`, which links no libc, so `printf` and
   `strlen` would be undefined references.
2. **Where does output go?** A real `printf` calls a `_write` syscall. On a PC
   the OS sends those bytes to a terminal; here there is no OS. You'd have to
   *retarget* the libc — write `_write` (and `_sbrk`, `_close`, `_fstat`,
   `_isatty`, `_lseek`, `_read`, `_exit`) so `_write` pushes bytes to your UART.

That "port a libc" route (install newlib or picolibc, add syscall stubs) is the
heavyweight option. For a small core, the lightweight option is better and is
what most bare-metal projects actually do at first:

> **Write a tiny freestanding library** with just the handful of functions you
> need, sending output straight to the UART.

Crucially, `<stdarg.h>` — which variadic functions like `printf` need — is a
**compiler** header, not a libc header, so it's available even with
`-nostdlib`. That's what makes a self-contained `printf` possible.

## The mini-library

`firmware.c` provides:

- `strlen`, `memset`, `memcpy` — the basics (the compiler also emits calls to
  `memcpy`/`memset` itself, so defining them keeps the linker happy).
- `uart_putc`, `uart_puts` — raw UART output.
- `kprintf(fmt, ...)` and `ksnprintf(buf, cap, fmt, ...)` — formatted output
  supporting `%c %s %d %u %x %X %%` with field width and `0`-padding
  (`%02d`, `%08x`).

The design is a single formatting core, `kvprintf`, driving a **sink** callback
so the same code serves both destinations:

```c
typedef void (*sink_fn)(void *ctx, char c);
// kprintf:   sink writes each char to the UART
// ksnprintf: sink writes each char into the caller's buffer
```

Number formatting peels off digits with `% base` and `/= base`:

```c
if (val == 0) tmp[n++] = '0';
while (val) { tmp[n++] = digits[val % base]; val /= base; }
for (int i = n; i < width; i++) put(ctx, pad);  // left-pad
while (n) put(ctx, tmp[--n]);                    // emit digits MSB-first
```

## Two gotchas you will hit

**1. Software divide must be linked (`-lgcc`).** This core has no hardware
multiply/divide, so `% 10` and `/ 10` compile to calls to libgcc's `__udivsi3`
and `__umodsi3`. With `-nostdlib`, GCC does *not* link libgcc automatically, so
you get:

```
undefined reference to `__udivsi3'
undefined reference to `__umodsi3'
```

Fix: add **`-lgcc`** at the end of the link line. (libgcc is pure RV32I software
routines — no syscalls — so it's safe on bare metal.)

**2. The string constants need `.rodata` in RAM.** The format strings live in
`.rodata`, so this builds on Step 12 — the Makefile already generates a RAM
data image and the SoC preloads it via `DATA_INIT`. Without that, the format
strings would read as zeros.

**3. (Bonus) printf is slow — give the testbench room.** Formatting with
software division takes far more cycles than the earlier demos. The simulation
safety-timeout in `tb/soc_tb.v` was raised to 500,000 cycles so the program can
finish and halt itself via syscon. If your own program seems to "hang," check
the timeout before suspecting the CPU.

There's also a compile flag worth noting: `-fno-tree-loop-distribute-patterns`
stops GCC from "optimizing" our hand-written `memcpy`/`memset` loops into calls
to `memcpy`/`memset` (which would recurse infinitely).

## The program

```c
#include "firmware.h"
#define RAM0 (*(volatile unsigned int *)0x00000000)

int main(void) {
    char buffer[100];
    ksnprintf(buffer, sizeof buffer, "Test %02d", 5);
    kprintf("%s\n", buffer);
    kprintf("Hello World from my custom risc-v processor ...\n");
    kprintf("formatting: dec=%d  uns=%u  hex=0x%08x  char=%c\n",
            -42, 1234u, 0xCAFE, '!');
    unsigned t0 = TIMER;
    for (volatile int i = 0; i < 5; i++) { }
    unsigned t1 = TIMER;
    RAM0 = t1 - t0;
    kprintf("loop took %u timer cycles\n", t1 - t0);
    halt(0);
}
```

## Run it

```bash
make soc
```

```
Test 05
Hello World from my custom risc-v processor ...
formatting: dec=-42  uns=1234  hex=0x0000cafe  char=!
loop took 32 timer cycles
[syscon] halt requested, exit code = 0
```

`snprintf` into a buffer, `printf`-style formatting with width and padding,
signed/unsigned/hex — all running on the CPU you built, with a ~150-line
library and zero host-libc dependency.

## If you do want the real libc later

Install newlib or picolibc for the toolchain, drop `-nostdlib`, and provide
syscall stubs — at minimum a `_write(fd, buf, len)` that loops calling
`uart_putc`, plus stubs for `_sbrk` (bump a heap pointer in RAM) and the
file/stat calls (return errors). Then `printf`, `malloc`, etc. work as usual.
That's a larger setup; the mini-library here covers most bare-metal needs
without it.

## Takeaway

"No `stdio.h`" doesn't mean no formatted output — it means no *operating system*
and no *bundled library*. On bare metal you either retarget a real libc or, more
simply, write the few functions you need and point their output at a peripheral
you built. Either way, the formatted text coming out of the UART is your own
CPU running your own C runtime.
