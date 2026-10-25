# Step 49 — Boot ROM, device tree and SBI: loading arbitrary programs

Every program in the previous 48 steps reached the CPU the same way: the
simulator `$readmemh`'d it into the instruction ROM before the first clock
edge. To run a different program you rebuilt the simulation (or, on the
FPGA, the bitstream, or reloaded memory over the PS's AXI port). And every
program hardcoded the machine. The UART is at `0x1000_0000` with status at
`+4`, RAM starts at 0 and is 32 KiB, the halt register is `0x2000_0000`.
Move one device and every program in `sw/` breaks.

A real computer solves both problems with three interfaces, and they are the
ones Linux needs before it runs its first instruction. A **boot ROM** is the
only thing in the machine at power-on, and it fetches the next program from
somewhere. A **device tree** (DTB) tells that program what machine it is
on: where the RAM is, which UART at which address, how fast the timer
ticks. The **SBI** is a call interface into M-mode firmware for what an
S-mode kernel cannot do itself, such as setting the machine timer or
resetting the system. The RISC-V boot protocol joins them: the program is
entered in S-mode with translation off, `a0` = hart ID and `a1` = the DTB's
physical address.

This step builds all three on a new platform, `soc_boot`. The boot ROM
receives programs over the UART as CRC-checked images. It puts the RAM
size and a command line into the DT, enters the program, and stays
resident as a small SBI. `make boot` runs it end to end. The ROM rejects
two bad images and then loads three different programs in a row, with a
reset between each. The first is an S-mode program that knows the machine
only through its DT. The second runs in M-mode and reboots the machine
through a DT node. The third is Step 37's picolibc demo, with its source
unchanged.

```
make uart16550   # the new ns16550a UART, register by register (Icarus)
make boot        # the whole boot chain (tools/rvboot; Verilator if installed)
tools/rvboot image prog.elf -o prog.rvbi --bootargs "..."   # your own image
```

`dtc` (`sudo apt-get install device-tree-compiler`) compiles the DT.
`make boot` uses Verilator (`sudo apt-get install verilator`) when it is
installed and takes seconds. Under Icarus it takes about 14 minutes,
because every byte crosses a real serial line: 10 bits at 16 clocks per
bit.

## The platform: one memory, standard devices

`rtl/soc_boot.v` differs from the previous SoCs in three ways.

**One memory behind both ports.** In every earlier SoC the I-port read a
ROM and the D-port a separate RAM, so no store could ever become an
instruction. That is why riscv-tests' `fence_i` was a documented gap on
ten cores (Step 40). A loader writes a program with stores and then runs
it, so here both ports read the same RAM array, and the boot ROM is
readable from both ports too. Its rodata, including the DTB, is in ROM.

**Standard devices at QEMU `virt`'s addresses.** A device tree is only
useful if the program reading it has a driver for what it describes, so
the devices are ones every RISC-V boot loader, OpenSBI and Linux already
support:

| Address | Device | DT `compatible` | Notes |
|---|---|---|---|
| `0x0000_1000` | boot ROM, 16 KiB | — | reset vector (`RESET_PC`) |
| `0x0010_0000` | test device | `sifive,test1`, `syscon` | `0x5555` power off, `0x3333 \| code<<16` fail, `0x7777` reset |
| `0x0200_0000` | CLINT | `sifive,clint0` | `msip` +0, `mtimecmp` +0x4000, `mtime` +0xBFF8 |
| `0x1000_0000` | UART | `ns16550a` | 8-bit registers at a 4-byte stride (`reg-shift = <2>`) |
| `0x8000_0000` | RAM, 256 KiB | `memory` | decoded across the whole 256 MiB window, so it aliases |

`rtl/uart16550.v` is a 16550 register interface (DLAB/divisor latch, LCR
framing, 16-deep RX and TX FIFOs, LSR, IIR with its four interrupt sources
in priority order, loopback) in front of Step 30's configurable framers.
The baud rate is `clock / (16 × divisor)`. `make uart16550` checks it
against a bit-banged line model in the testbench: framing for 8N1, 7E2
and 8O1, back-to-back characters, the trigger level and the
character-timeout interrupt, overrun of the 17th byte, parity and framing
errors with the line-status interrupt taking priority, the THR-empty
interrupt and its two acknowledge rules, and loopback. Read side effects
(RBR pops, LSR clears errors, IIR acknowledges THR-empty) are keyed on a
real D-port request, the lesson of Step 33.

`rtl/clint_sifive.v` is the CLINT layout the rest of the world uses. Step
27's `clint.v` packed the same registers into 16 bytes. **A reset through
the test device** (`0x7777`) resets the core and the devices but not the
memories, so the ROM starts over and can take the next program.

**Two changes to `cpu_pipe_u`**, both small:

- **`time` / `timeh` (0xC01 / 0xC81)** read a new `mtime` input, which
  `soc_boot` wires to the CLINT. Before this step those CSRs read 0. An
  S-mode kernel reads the time through this CSR; it cannot reach
  `mtime`, and on hardware without the CSR, OpenSBI has to trap and
  emulate every read. The other SoCs tie `mtime` to 0, which is what they
  read before.
- **`FENCE.I`** now redirects to `pc + 4` from EX, so the instructions
  behind it are fetched again. It used to decode as a NOP. On one memory
  with no I-cache, that is all a fence needs to do: the older stores have
  already written memory by the time the refetch reads it.

## The boot image, and a loader that checks before it writes

`tools/rvboot image` turns any statically linked ELF into an image
(`sw/boot/bootimg.h`). Each `PT_LOAD` program header becomes a segment
with an address, a file size and a memory size (the difference is `.bss`).
The image also records the entry point, whether to enter in M- or S-mode,
and up to 255 bytes of command line:

```
header   32 B   magic "RVBI", version, nseg, entry, flags, cmdline_len,
                data_size, data_crc, hdr_crc
segments 12 B each    addr, filesz, memsz
cmdline  cmdline_len B
data     filesz B per segment, in order
```

The two CRC-32s split the trust. `hdr_crc` covers the header, the segment
table and the command line, and it is checked **before the first byte of
data is written**. After it, the ROM checks every segment against the
payload area: above the 16 KiB of RAM the firmware keeps, below the DTB,
with no wrap-around. It also checks that the sizes add up and that the
entry point lies inside loaded bytes. A corrupted length or address
therefore never gets to scribble over the ROM's own variables. `data_crc`
is checked once the data has landed.

The stream is **one-way**. There is no handshake and no acknowledgement,
so on real hardware `stty raw; cat prog.rvbi > /dev/ttyUSB0` is enough.
The ROM hunts for the 4-byte magic and skips anything before it (line
noise, a terminal's banner). After an error it reads and discards
whatever is still arriving until the line has been quiet for 32 character
times, then reports and asks again:

```
boot> RVBI v1: 1 segment, entry 0x80000100, S-mode
  segment 0: 0x80000100  file    64  mem    64
  error: segment 0 [0x80000100, 0x80000140) is outside the payload area [0x80004000, 0x8003e000)
  (discarded 64 more bytes)
boot>
```

### No flow control: two bugs the test found

A one-way stream has a cost: the ROM must keep up. A byte arrives every
160 clocks, and the UART can hold 16 of them. The first run of `make boot`
hung after printing the first header line. The ROM had printed its
summary of the header while the rest of the image was still arriving.
Sending a 50-character line takes exactly as long as receiving 50
characters, so the FIFO overflowed. So the loader now prints **nothing**
until the image is complete, or until the rest of a bad one has been
drained. Every message comes after the data.

The next run still lost four bytes, now during the 44 bytes of header and
segment table. The ROM computed the header CRC only after receiving them,
with a bit-serial CRC (eight shift/xor steps per byte), and that took
about 2,500 cycles. That is 16 byte-times, a full FIFO. The fix has two
parts. The CRC is folded in as each byte arrives (`rx_bytes()`), so no
step of the loader is ever more than a few bytes behind. And it works a
nibble at a time from a 64-byte table (`lib.c`), not bit by bit. The
testbench now records the RX FIFO's high-water mark, which is **1 of 16**:
across 19.8 KB of images, every byte is read before the next one arrives.
Overrun, parity and framing errors are still caught: the loader keeps the
LSR error bits it sees and refuses the image if any are set.

## The device tree

`sw/boot/rvfs-soc.dts` describes the platform with the bindings Linux and
OpenSBI use: `cpus` with `timebase-frequency`, a `cpu@0` with
`riscv,isa`, `riscv,isa-extensions`, `mmu-type = "riscv,sv32"` and its
`riscv,cpu-intc`, `memory@80000000`, a `reserved-memory` node marking the
firmware's RAM `no-map` (as OpenSBI does), the CLINT with its
`interrupts-extended`, the UART with `reg-shift`, `reg-io-width`,
`clock-frequency` and `current-speed`, and `syscon-poweroff` /
`syscon-reboot` nodes pointing at the test device by phandle. It is run
through the C preprocessor before `dtc`, as Linux's DTS files are. Every
number comes from `sw/boot/platform.h`, the same header the ROM is
compiled with, so the tree cannot disagree with the ROM that ships it. The
ROM links in the 1,875-byte DTB with `.incbin`.

Two values are known only at boot, and the ROM fills them in. This is the
same job U-Boot and OpenSBI do with their "fixups":

- **The RAM size.** The DTS says `reg = <0x80000000 0>`. The ROM probes
  RAM by aliasing: the decoder ignores the address bits above the RAM's
  size, so `RAM_BASE + size` is the first offset that reads back the word
  at `RAM_BASE`. Only that one word is written (and then restored).
- **`/chosen/bootargs`**, the image's command line.

`fdt.c` is a small libfdt: walking tokens, finding nodes by path, alias
and phandle, reading properties and string lists. It also has
`fdt_setprop()`, which edits the tree in place. A property that grows or
shrinks, or a new one, opens or closes a gap in the structure block and
moves the strings block behind it. A new name is appended to the strings
block. The ROM copies the DTB to the last 8 KiB of RAM and edits it there.
`make boot` hands the edited blob, taken from simulated RAM, to `dtc` and
diffs it against the original. Exactly two properties change:

```
-		bootargs = [00];
+		bootargs = "rvfs.payload=libc_demo";
-		reg = <0x80000000 0x00>;
+		reg = <0x80000000 0x40000>;
```

## The SBI

Once the payload runs, the ROM never runs again except through the trap
vector it leaves in `mtvec` (`sbi_trap_entry`). That entry swaps to the
firmware's stack through `mscratch`, saves every register, and lets
`rom_sbi.c` read the call from `a0`…`a7` and write the answer back. Before
the `mret`, the ROM delegates to S everything an S-mode kernel handles
itself. In `medeleg` that is misaligned fetch, illegal instruction,
breakpoint, ecall from U, and the three page faults. In `mideleg` it is
the S-level software, timer and external interrupts. Two things stay in M:

| trap | what the SBI does |
|---|---|
| ecall from S (cause 9) | an SBI call: `a7` = extension, `a6` = function; `a0` = error, `a1` = value; `mepc += 4` |
| machine timer interrupt | S cannot see `mtimecmp`, so the SBI forwards it: clear `MTIE`, set `mip.STIP`. STIP is delegated, so the payload takes it at `stvec`. `set_timer` re-arms: new `mtimecmp`, clear STIP, set MTIE |
| anything else | report it and fail the run |

The implementation is SBI v2.0's BASE (version, implementation ID
`"RVFS"`, `probe_extension`, `mvendorid`/`marchid`/`mimpid`), TIME, DBCN
(the debug console Linux's `earlycon=sbi` uses), SRST (shutdown, reboot),
and the v0.1 legacy `set_timer` / `console_putchar` / `console_getchar` /
`shutdown`. DBCN takes buffers by physical address, and the SBI refuses
one that is not in the payload's memory. Otherwise an S-mode program could
read the firmware's RAM through the console.

## Three programs, nothing hardcoded

All three are linked to `0x8000_4000` by `sw/boot/payload.ld` and start in
`payload_start.S`. It sets `gp` and a stack inside the program's own
`.bss` (the program owns no other RAM until it has read the DT), then calls
`main(hartid, dtb)`. When `main` returns, it shuts down through SBI SRST.

**`dtdemo.c`** runs in S-mode. It does not include `platform.h`. It probes
the SBI and checks every answer, then prints the whole tree it was handed,
in DTS syntax, the way `dtc -O dts` would. It then reads what a kernel
would: the ISA string, the MMU, the timebase, the memory and the reserved
region. It follows `/chosen/stdout-path` through `/aliases` to
`serial@10000000`, checks it is `ns16550a`, and **drives that UART itself**
with the base, stride, access width and divisor
(`clock-frequency / 16 / current-speed`) from the tree. With the timebase
from the DT, it programs three timer interrupts 100 µs apart through SBI
TIME. It takes them at its own `stvec` and checks that none arrived early.
It also takes an `ebreak` that M never sees. It parses its command line:
`rvfs.ticks=3` sets the number of ticks, and `rvfs.exit=reboot` makes it
leave through SBI system reset instead of shutdown.

**`mhello.c`** is entered in **M-mode** (image flag `RVBI_F_MMODE`, `rvboot
image --mmode`). This is the escape hatch for bare-metal programs that
want the whole machine. It still finds its console in the DT, and it
reboots the way Linux's `syscon-reboot` driver would: it follows the
node's `regmap` phandle to the test device, and writes `value` at `reg +
offset`.

**`libc_demo.c`** is Step 37's source file, unchanged. Step 37's retarget
wrote UART registers at a fixed address. `sbi_libc.c` binds picolibc's
`stdout` to SBI DBCN and `_exit` to SBI shutdown instead, so the program
runs on any machine with an SBI underneath. Linking picolibc's integer-only
`printf` (`--defsym=vfprintf=__i_vfprintf`) shrinks it from 13 KB to 3.7 KB.
At 160 clocks a byte, image size is also load time.

## FENCE.I, and a test that can tell

On the single memory, the official `fence_i` test passes, on a new
riscv-tests core `pipe_u_uni` (`cpu_pipe_u` with one memory for fetch and
data, `tb/rvtest_pu_tb.v -DRVT_UNIFIED`): **91/91**, where every other
`cpu_pipe_u` configuration reports 90 plus the gap. But it also passes
with the core's refetch removed. The test always reaches the code it
patched through a `jalr`, and that jump's redirect flushes the pipeline
anyway.

`dtdemo` makes the case directly. It stores `li a0, 1` over the
instruction right behind the store, with one instruction between them:

```
[storing an instruction]
  store over the next instruction, then nop:     a0 = 0 (the stale copy ran)
  store over the next instruction, then fence.i: a0 = 1     ok
```

When the store writes memory in MEM, its target is already in ID. Without
a fence, the stale copy runs; this is the "unspecified" result the ISA
warns about. With the refetch removed from the core, the second line
fails. The ROM itself issues a `fence.i` before the `mret` into every
payload.

## What `make boot` shows

`tools/rvboot test` builds five images and streams them into the UART
pin, one per `boot>` prompt (19,782 bytes). It then compares all 184 lines
the machine prints with `tb/boot_expected.txt`. Sizes, CRCs and cycle
counts are wildcards there; `rvboot test --update` rewrites the file from
a run. Finally, `dtc` checks the DTB left in RAM:

| # | image | outcome |
|---|---|---|
| 1 | line noise, then a 64-byte image with one data bit flipped in transit | `data CRC32 0xb2394f88, image says 0xeaca17c1` |
| 2 | a well-formed image aimed at the firmware's RAM | rejected before any write; 64 bytes discarded |
| 3 | `dtdemo`, S-mode, `bootargs "console=hvc0 earlycon=sbi rvfs.ticks=3 rvfs.exit=reboot"` | every check passes, then SBI reboot |
| 4 | `mhello`, M-mode | reboots through `/reboot` |
| 5 | `libc_demo`, S-mode, `bootargs "rvfs.payload=libc_demo"` | Step 37's output byte for byte, then SBI shutdown |

```
[rvboot] halted, exit code 0, 5032473 cycles, 2 resets, 5 images sent
[rvboot] 19782 bytes in, 7051 bytes out; RX FIFO peak 1 of 16
[rvboot] UART transcript matches tb/boot_expected.txt (184 lines)
BOOT: ALL PASS
```

The numbers check out. The loader reports 161–164 cycles per byte against
a wire time of 160: the run is limited by the serial line, not by the ROM.
That is also why the FIFO never holds more than one byte. About 3.2M of
the 5M cycles are spent receiving images (19.8 KB × 160) and about 1.1M
transmitting the 7.1 KB of output, also at 160 cycles per character. The
rest is computation and the drain after each bad image.

## What's verified here

- `make uart16550`: the 16550's registers, framing (8N1, 7E2, 8O1),
  divisor, FIFOs, overrun, parity/framing errors, all four interrupt
  sources and their priority and acknowledge rules, loopback, against a
  line model in the testbench.
- `make boot`, under both Verilator and Icarus (the two give the same
  5,032,473 cycles): the boot ROM's magic hunt, header and data CRCs and range
  checks, with recovery from both bad images. Three programs run in
  sequence across two resets, in S-mode and M-mode. Every SBI call
  `dtdemo` makes is checked: probe results, DBCN byte counts and the
  refused firmware address, timer interrupts at or after their deadlines.
  A delegated `ebreak` is taken in S. `FENCE.I` makes a just-stored
  instruction visible. The fixed-up DTB is accepted by `dtc`, and differs
  from the original only in the two fixups. The 184-line transcript
  matches.
- `tools/rvtests --core pipe_u_uni`: riscv-tests 91/91, including
  `fence_i`. Regressions after the `cpu_pipe_u` changes: `make pipe-u`
  (riscv-tests 90/90 in M and with Sv32 on in U), `pipe-u-sv`, `cache`
  (riscv-tests through the caches), `vec`, `bench-counters`, and all nine
  `rvgen-all` presets pass.

## Cost

Yosys 0.33, `synth_xilinx -flatten -abc9 -arch xc7`. The core is Step 48's
minimal configuration (RV32IM, M-mode only, no MMU, no Zb*, no V, with
`ZICNTR`), before and after this step:

| | LUTs | FFs | CARRY4 | LUTRAM |
|---|---:|---:|---:|---:|
| `uart16550` | 298 | 181 | 36 | 4 RAM32M (the FIFOs) |
| `uart_full` (Step 30), for comparison | 262 | 152 | 28 | — |
| `clint_sifive` | 194 | 129 | 22 | — |
| `cpu_pipe_u`, Step 48 | 7,156 | 5,143 | 1,030 | 12 |
| `cpu_pipe_u`, + `time` CSR + `FENCE.I` | 7,397 | 5,144 | 1,030 | 12 |

Most of the core's 241 extra LUTs widen the CSR read multiplexer for the
two `time` halves. The flip-flop is `idex_fencei`. The CLINT's carries
are the 64-bit `mtime` incrementer and the 64-bit compare.

## Honest status

- Verified in simulation only (Verilator and Icarus). `soc_boot`'s
  memories are ideal, combinational arrays, so it is not an FPGA design
  as it stands; the UART and CLINT synthesize on their own. Running this
  on the board means putting the ROM and RAM in block RAM (registered
  reads), or behind Step 43's caches. Then `FENCE.I` must also
  invalidate the I-cache and write back the D-cache, which this step's
  plain refetch does not do.
- The 16550 latches its error bits when a bad character arrives, not when
  it reaches the head of the FIFO, and has no break detection, no stick
  parity and no modem-status interrupt. Its interrupt output is not
  connected, because the platform has no PLIC yet. For Linux, the PLIC
  of Step 33 needs an S-mode context wired to `SEIP` and a DT node.
- The CLINT's `msip` register exists, but it does not reach the core:
  `cpu_pipe_u` has no machine-software-interrupt input. With one hart
  that only matters to software that sends itself an IPI.
- Unmapped addresses read 0 and swallow writes. There is no bus error,
  so no access-fault exception; Linux probing a missing device would see
  zeros, not a fault.
- The SBI has no HSM, IPI or RFENCE extensions (there is one hart), and
  no PMP: an S-mode payload that ignores the DT's `reserved-memory` can
  still write the firmware's RAM. Misaligned loads and stores are not
  emulated (the core's RAM silently mis-handles them; see Step 40).
- Linux itself is further off. It needs megabytes of RAM, not 256 KiB,
  and a page-table walker that either sets the A and D bits or faults
  when they are clear (Svadu or Svade); `ptw.v` does neither. It also
  needs a console driver (the `ns16550a` binding is now the right one)
  and interrupts through a PLIC. The boot protocol, the DT and the SBI
  calls a kernel makes before its own drivers run are what this step
  delivers.
- The ROM trusts what it is sent. A CRC catches line errors, not a
  malicious image; there is no signature check.

## Takeaway

Loading a program turned out to be the easy part. What makes a program
arbitrary is that it no longer has to know the machine. `dtdemo` drives a
UART it found by following a string through `/aliases`, ticks a timer
whose rate it read from `/cpus`, and asks M-mode for what it may not do
itself. The machine it runs on is described in one 1.9 KB blob, written
once in `platform.h`.

## Files

| file | |
|---|---|
| `rtl/soc_boot.v` | the platform: boot ROM, unified RAM, test device (power off / fail / warm reset) |
| `rtl/uart16550.v`, `tb/uart16550_tb.v` | the ns16550a-compatible UART and its register-level test (`make uart16550`) |
| `rtl/clint_sifive.v` | the standard CLINT layout, `mtime` out to the core |
| `rtl/cpu_pipe_u.v` | `mtime` input → `time`/`timeh`; `FENCE.I` refetches |
| `rtl/soc_pipe_u.v`, `rtl/soc_pipe_c.v`, `rtl/oz/oz_rv_soc.v`, `tb/rvtest_p[uc]_tb.v` | tie the new `mtime` port to 0 |
| `sw/boot/platform.h`, `sw/boot/rvfs-soc.dts` | the memory map, once; the device tree built from it |
| `sw/boot/rom_start.S`, `rom_main.c`, `rom_sbi.c`, `rom.h`, `rom.ld` | the boot ROM: reset, loader, DT fixups, payload entry, resident SBI |
| `sw/boot/bootimg.h` | the boot image format |
| `sw/boot/fdt.[ch]`, `lib.[ch]`, `ns16550.[ch]`, `sbi.h` | DTB library, small libc + nibble CRC-32, 16550 driver, SBI definitions + S-mode calls |
| `sw/boot/payload_start.S`, `payload.ld` | entry and link script for loaded programs |
| `sw/boot/dtdemo.c`, `mhello.c`, `sbi_libc.c` | the S-mode DT/SBI demo, the M-mode payload, picolibc on the SBI |
| `tb/boot_tb.v`, `tb/boot_expected.txt` | the serial cable: sends images per prompt, decodes TX, dumps the DTB |
| `tools/rvboot` | ELF → image, and the system test (`make boot`) |
| `tools/rvtests` | new core `pipe_u_uni`: `fence_i` passes |
