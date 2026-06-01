# Step 12 — Making string and array constants work (initialized data)

If you change the demo to use a real string constant:

```c
uart_puts("Hello World\n", 12);   /* instead of putc('H'); putc('i'); ... */
```

…it compiles and runs, but **prints nothing**. This isn't a CPU bug — it's the
"initialized data" limitation we flagged in Steps 10 and 11, finally biting. It's
worth walking through because diagnosing it teaches how programs are laid out in
memory.

## Why it prints nothing

Disassemble the program and look at how the string is read:

```
00000010 <main>:
  14: li  a5, 124        # a5 = 0x7c  -> address of "Hello World"
  20: lbu a4, 0(a5)      # load a byte of the string FROM ADDRESS 0x7c
  24: sb  a4, 0(a3)      # store it to the UART (0x10000000)
  28: addi a5, a5, 1
  2c: bne  a5, a2, 20    # loop over the bytes
```

And check where the string lives:

```
$ riscv64-unknown-elf-objdump -h socdemo.elf
Idx Name      Size      VMA       LMA
  0 .text     0000007c  00000000  00000000
  1 .rodata   0000000c  0000007c  0000007c     <- the string, at 0x7c
```

So the compiler put `"Hello World\0"` in the `.rodata` section at address
`0x7c`, and `main` reads it with `lbu` loads from `0x7c`. Those loads go through
the bus to **RAM** (address `0x7c` is in the RAM region). But we only ever loaded
the *code* into instruction memory — **nothing put `.rodata` into RAM**. RAM at
`0x7c` is zero, so the CPU dutifully transmits zero bytes, and you see nothing.

The earlier char-literal version (`uart_putc('H')`) worked because each
character was an **immediate** baked into an `li` instruction — no memory read,
so no `.rodata` needed.

This is exactly the gap between "a program's image" and "what's actually in the
machine's memories." On a real computer the OS (or a bootloader) copies the
program's data sections into RAM before `main` runs. We have neither, so we do
it ourselves.

## The two address spaces, and why we can't just copy in `crt0`

A common embedded trick is a `crt0` copy loop: the linker keeps a *load* copy of
`.data` in ROM (its LMA) and a *run* location in RAM (its VMA), and startup code
copies LMA→VMA. That requires the CPU to **read the ROM with load instructions**.

Our core is **Harvard**: instruction memory is fetched by the PC and is *not* on
the data bus, so load instructions can't read it. A `crt0` copy loop has no
source to copy *from*. (Unifying the two memories — a von Neumann design with one
memory feeding both fetch and load/store — is the alternative; it makes data
constants "just work" but needs a memory with separate fetch and data ports. A
good larger refactor, but more than we need here.)

## The fix: preload RAM with the initialized data

Since this is simulation, the simplest correct approach is to **initialize RAM's
contents** with the `.rodata`/`.data` bytes at their link addresses — the same
way you'd initialize block RAM on an FPGA. Two small changes:

### 1. Let the RAM accept an init image

`rtl/dmem.v` gains an `INIT_FILE` parameter; after zeroing, it loads the file:

```verilog
module dmem #(parameter BYTES = 1024, parameter INIT_FILE = "") ( ... );
    reg [7:0] mem [0:BYTES-1];
    integer i;
    initial begin
        for (i = 0; i < BYTES; i = i + 1) mem[i] = 8'd0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);   // overlay data
    end
```

`soc.v` passes a new `DATA_INIT` parameter to the RAM instance, and `soc_tb.v`
supplies the filename.

### 2. Generate the RAM image from the ELF

`objcopy` can emit a byte-wide hex image of just the data sections, complete
with `@address` records that `$readmemh` understands:

```bash
riscv64-unknown-elf-objcopy -O verilog --verilog-data-width=1 \
    --only-section=.rodata --only-section=.data --only-section=.sdata \
    build/socdemo.elf /dev/stdout | tr -d '\r' > sw/socdemo_data.hex
```

The result places the bytes exactly where the loads expect them:

```
@0000007C
48 65 6C 6C 6F 20 57 6F 72 6C 64 0A 00       # "Hello World\n\0"
```

`@0000007C` tells `$readmemh` to start loading at byte index `0x7c` of the RAM
array — the same address the program reads. (The `tr -d '\r'` just strips the
carriage returns objcopy emits.)

## Run it

```bash
make soc
```

```
---- UART output ----
Hello World
[syscon] halt requested, exit code = 0
timer delta measured by program = 32 cycles
```

The string constant now prints, because the bytes it points to are really in
RAM. The same mechanism makes **initialized global variables** (`int table[] =
{1,2,3};`, `const char *msg = "...";`) work — they're all just `.data`/`.rodata`
that now gets loaded.

## What still won't work

- **Writable globals that the program changes and re-reads** work *only* if the
  program tolerates starting from the linked initial values — which it now does,
  since we preload them. Good.
- **`.bss` (zero-initialized globals)** happen to be fine here because our RAM
  powers up zeroed; on real hardware `crt0` would zero `.bss` explicitly.
- **Self-modifying code / reading code as data** still can't work in this
  Harvard split — that needs the unified-memory design mentioned above.

## Takeaway

"Nothing prints" from a string constant is almost always this: the data section
isn't in the memory the loads target. The fix is to get initialized data into
RAM — by preloading it (what we did) or by copying it from a readable ROM at
startup (needs a von Neumann memory). Now you can use ordinary C strings and
constant tables in your programs.
