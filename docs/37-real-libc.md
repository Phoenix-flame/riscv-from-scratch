# Step 37 — A real C library: picolibc, with full `printf` and `malloc`

For a long time this project got by with a hand-rolled standard library. `firmware.c` had a `kprintf` that understood a handful of format specifiers, a `memcpy`, a `memset`, and not much else; the FreeRTOS build leaned on a pair of header *shims* under `sw/freertos/shim/` whose entire job was to declare `memcpy` and friends so the kernel would compile. None of it was a C library — it was just enough of one to keep the linker quiet. There was no `malloc`, no `snprintf`, no field widths or precision, no `strtol`, none of the hundred small things real code assumes.

This step replaces all of that with picolibc: a genuine, BSD-licensed C library built for microcontrollers, with a complete `printf`, a real `malloc`/`free` heap, and the usual `string.h`/`stdlib.h` surface. The interesting part is how *little* the core has to provide to host it. A full C library is a large thing, but the contract it needs from a bare-metal platform is tiny: somewhere to send a character, a region of memory to hand out, and a way to stop. Supply those three hooks and everything else — the formatting engine, the allocator, the string routines — is library code that simply runs.

## The three hooks a C library actually needs

picolibc's `printf` doesn't know what a UART is. It formats into a `FILE`, and a `FILE` is little more than a function pointer: a `put` callback that takes one character. So the entire output path is one function that polls the memory-mapped UART and writes a byte, wrapped in a `FILE` that we name `stdout`. picolibc's `printf`, `puts`, `putchar`, and the rest all flow through it. Because the callback polls the UART's ready bit before writing, the very same object works on the simulation UART (which is always ready and prints via `$write`) and on the synthesizable `uart_hw` (which actually goes busy while it serializes a bit at a time).

`malloc` is even less work, because picolibc ships its own allocator and its own `sbrk`; all it wants from the platform is to know where the heap may live. The linker script answers that by exporting two symbols, `__heap_start` and `__heap_end`, bracketing the RAM between the end of the program's data and the base of the stack. picolibc's `sbrk` hands that region out a chunk at a time, and `malloc`/`free` build on it. No allocator code is ours.

The third hook is `_exit`, which writes the SYSCON halt register so a finished program stops the core (and, in simulation, ends the run with an exit code). That is the whole platform contract: a `put`, a heap, and an exit.

## Startup, and the one habit picolibc insists on

The old `crt0` set the stack pointer, called `main`, and stashed the return value — and pointedly did *not* zero `.bss`, because the old demos initialized their globals by hand. picolibc is not so forgiving: its allocator and its stdio keep state in zero-initialized globals and genuinely require `.bss` to start as zero. So the picolibc startup does three things the old one skipped or split differently: it sets the global pointer `gp` (so picolibc's small-data accesses resolve), points the stack at the top of RAM, and zeroes `.bss` before calling `main`. On return it publishes the exit code and halts. It is a dozen instructions, but each one is load-bearing in a way the old startup's were not.

The memory model is the same mirrored layout the rest of the project uses: the program image is loaded into both the instruction ROM and the data RAM, so code, read-only constants, and initialized data all share one address space starting at zero and need no separate flash-to-RAM copy. The string constants that `printf`'s format strings point at are simply present in RAM because the image is there too. Above the program sits the heap, and above that the stack.

## The demo, checked to the byte

`make libc` compiles a program that does the things the old mini-library couldn't and runs it on a SoC with the simulation UART. It prints signed and unsigned integers, zero-padded and left- and right-justified fields, hexadecimal, and characters; it `malloc`s an array, fills and sums it, `malloc`s a string and builds it with `strcpy`/`strcat`/`strlen`, frees both, and allocates again to show the freed space comes back. The testbench does not eyeball the output — it snoops every byte the UART transmits and compares the whole stream, byte for byte, against the exact expected text computed on the host (with newlines cooked to CRLF the way the retarget emits them). All 176 bytes match, which means the formatting, the allocator, and the string routines are all behaving as a real C library should.

## Swapping the shims under FreeRTOS

The payoff that motivated this is the FreeRTOS build. Previously it compiled against the header shims and printed through the `kprintf` mini-library; now it compiles against picolibc's headers, links picolibc, and its `main.c` calls real `printf` and `exit`. The shim directory is gone entirely, and the build still produces a working image: the producer-consumer demo runs exactly as before — the consumer task prints the values it pulls off the queue and the run halts cleanly — except every line now comes out of genuine `printf`. The text segment grew by about eleven kilobytes, which is simply what a real formatting engine costs and a fair price for never again hand-writing a format specifier.

One detail mattered for linking. The RTOS SoC's core implements `M` and `A` but not the compressed `C` extension, so the build links picolibc's `rv32im` variant — which contains no compressed instructions the core couldn't execute — into the `rv32ima` application. The two share the `ilp32` ABI, so they interoperate cleanly; the library simply doesn't use atomics or compression itself, while the application is free to.

## What's verified here

`make libc` runs a compiled picolibc program and checks its entire UART output byte-for-byte (176 bytes) against a host-computed reference, exercising `printf` formatting, `malloc`/`free` with heap reuse, and the `string.h` routines. The FreeRTOS image rebuilds against picolibc with the shim directory deleted, and `make freertos-run` shows the producer-consumer demo running to completion through real `printf` and halting with exit code 0. The picolibc retarget is a single small file; the allocator, formatter, and string code are all unmodified library code.

## Honest status

- picolibc's `printf` here is the integer/string/width/precision-complete formatter; floating-point `printf` is available in picolibc but is not exercised by this integer-core demo. On a soft-float or `F`-equipped build it would pull in the float formatting path.
- The standalone demo captures output through the simulation UART for an exact byte comparison. The retarget polls the UART ready bit, so the identical object runs on the synthesizable `uart_hw`; that hardware path is inherited from earlier steps and not re-verified here.
- FreeRTOS still uses its own `heap_4` for task and queue allocation; picolibc's `malloc` is available to application code, and the two heaps coexist without interfering. Library `printf` is called from a single task in this demo — picolibc's default stdio is not guaranteed reentrant, so a design that printed from several tasks at once would need picolibc's lock hooks supplied.
- The older standalone demos still use the `firmware.c` mini-printf; they were left untouched. picolibc supersedes it, and migrating them is mechanical follow-up work, not a rebuild.
- Requires picolibc installed for the target (`picolibc-riscv64-unknown-elf`) and, for the FreeRTOS target, a FreeRTOS-Kernel checkout. Verified in simulation only.

## Takeaway

A "real C library" on bare metal sounds heavy, and the library itself is — but the seam between it and the hardware is almost nothing. picolibc asks the platform for one function that emits a character, two symbols that bound a heap, and one function that halts. Provide those and the entire apparatus of `printf`, `malloc`, and `string.h` comes alive, the hand-rolled mini-printf and the compile-me-quiet header shims can be deleted, and even FreeRTOS prints through the genuine article. The lesson is that the boundary between an embedded program and a standard library is a handful of named hooks, not a porting marathon.
