# Step 08 — Assemble a real program and run it

Until now we either hand-encoded instructions or generated them with a Python
helper. This step closes the loop properly: we install a real RISC-V assembler,
write a program in **assembly**, turn it into the hex format our instruction
memory loads, and run it on the CPU from Step 07. No more encoding by hand.

Files:
- `sw/sum.s` — the assembly program
- `sw/bin2hex.py` — converts a raw binary into `$readmemh` hex
- `sw/build.sh` — one command: assemble → link → objcopy → hex
- `tb/sum_tb.v` — runs `sum.hex` and checks the result

## Install the toolchain

We only need the assembler/linker (binutils), not a full C compiler:

```bash
sudo apt-get install -y binutils-riscv64-unknown-elf
```

This gives you `riscv64-unknown-elf-as`, `-ld`, `-objcopy`, and `-objdump`.
Despite the `riscv64` in the name, it assembles 32-bit RV32I fine when you pass
the right flags.

## The program

`sw/sum.s` computes 1 + 2 + ... + 10 and stores the result:

```asm
        .section .text
        .globl _start
_start:
        addi    x1, x0, 0      # x1 = sum   = 0
        addi    x2, x0, 1      # x2 = i     = 1
        addi    x3, x0, 11     # x3 = limit = 11
loop:
        bge     x2, x3, done   # if i >= 11, leave the loop
        add     x1, x1, x2     # sum += i
        addi    x2, x2, 1      # i++
        jal     x0, loop       # jump back (rd=x0 throws away the return addr)
done:
        sw      x1, 0(x0)      # mem[0] = sum
halt:
        jal     x0, halt       # spin forever
```

A few assembly conventions worth noting:

- **Labels** (`loop:`, `done:`) are names for addresses. The assembler computes
  the branch/jump offsets for you — a big reason to use it instead of
  hand-encoding.
- **`jal x0, loop`** is an unconditional jump: `jal` always saves the return
  address into `rd`, but writing it to `x0` (which ignores writes) discards it,
  giving a plain "goto". The disassembler shows this as the pseudo-instruction
  `j loop`.
- **`bge x2, x3, done`** exits when the counter reaches the limit. We use
  `bge` (≥) rather than counting down so the C-like `for (i=1; i<11; i++)`
  structure is obvious.
- **The final `jal halt, halt`** is a self-loop — a common bare-metal idiom for
  "program finished" since there's no OS to return to.

## The four-step build

A CPU's instruction memory wants raw machine-code words. Getting there from
`.s` is a small pipeline; `sw/build.sh` runs all of it:

**1. Assemble** `.s` → object file:
```bash
riscv64-unknown-elf-as -march=rv32i -mabi=ilp32 sw/sum.s -o build/sum.o
```
- `-march=rv32i`: target the base 32-bit integer ISA only (no extensions),
  matching exactly what our CPU implements.
- `-mabi=ilp32`: the 32-bit integer ABI.

**2. Link**, placing `.text` at address 0 (where our PC starts):
```bash
riscv64-unknown-elf-ld -m elf32lriscv -Ttext=0x0 build/sum.o -o build/sum.elf
```
- `-m elf32lriscv`: produce a 32-bit little-endian RISC-V ELF.
- `-Ttext=0x0`: put the code at address 0, so labels resolve to the addresses
  our instruction memory uses.

**3. Extract raw bytes** from the ELF:
```bash
riscv64-unknown-elf-objcopy -O binary build/sum.elf build/sum.bin
```
This strips the ELF wrapper, leaving only the instruction bytes.

**4. Convert to hex words** for `$readmemh`:
```bash
python3 sw/bin2hex.py build/sum.bin > sw/sum.hex
```
`bin2hex.py` reads 4 bytes at a time, interprets them little-endian (RISC-V's
byte order), and prints one 8-digit hex word per line — exactly the format
`imem` loads.

### Inspect what you built

`objdump -d` disassembles the ELF so you can confirm the machine code matches
your intent:

```
00000000 <_start>:
   0: 00000093   li   ra,0          # addi x1,x0,0  (ra = x1)
   4: 00100113   li   sp,1          # x2 = 1
   8: 00b00193   li   gp,11         # x3 = 11
0000000c <loop>:
   c: 00315863   bge  sp,gp,1c <done>
  10: 002080b3   add  ra,ra,sp
  14: 00110113   addi sp,sp,1
  18: ff5ff06f   j    c <loop>
0000001c <done>:
  1c: 00102023   sw   ra,0(zero)
00000020 <halt>:
  20: 0000006f   j    20 <halt>
```

(The toolchain prints the ABI register *names* — `ra`=x1, `sp`=x2, `gp`=x3,
`zero`=x0 — and recognizes `addi rd,x0,n` as the `li` pseudo-instruction and
`jal x0,target` as `j`. Same machine code, friendlier display.) That resulting
`sw/sum.hex` is just nine words:

```
00000093  00100113  00b00193  00315863  002080b3
00110113  ff5ff06f  00102023  0000006f
```

## Run it

The Makefile wraps the whole flow — assemble *and* simulate — in one target:

```bash
make sum
```

It rebuilds `sw/sum.hex` from `sw/sum.s` if the source changed (via a pattern
rule), then compiles the CPU with `sum_tb.v` and runs it. Output:

```
Built sw/sum.hex
x1 (sum)   = 55
mem[0..3]  = 00 00 00 37
ALL TESTS PASSED  (sum = 55)
```

`x1 = 55` and `mem[0]` holding `0x37` (= 55) confirm the CPU ran your compiled
program correctly: it executed the loop ten times, accumulated the sum, and
stored it to memory. The CPU you built runs real RISC-V code.

## Your workflow from here

To run your own program:

1. Write `sw/myprog.s`.
2. `./sw/build.sh sw/myprog.s` (check the disassembly it prints).
3. Point a testbench at `sw/myprog.hex` via the `INIT_FILE` parameter:
   ```verilog
   cpu #(.INIT_FILE("sw/myprog.hex")) dut ( ... );
   ```
4. Compile and run with `iverilog`/`vvp`, or add a Makefile target.

Try a Fibonacci sequence, a multiply-by-repeated-addition routine, or a small
array sum using `lw`/`sw` in a loop — the core supports all of RV32I's base
integer instructions.

## Checkpoint

The loop is closed: assembly source → machine code → running on your CPU in
simulation, with the result verified. You have a genuine, programmable RV32I
processor.

## Next

`docs/09-debugging-in-gtkwave.md` — the final step: how to read the waveforms
to understand and debug execution, including a practical recipe for tracing a
single instruction through the datapath and spotting common bug signatures.
