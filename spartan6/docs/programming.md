# Programming the board

There are **two** different things called "programming" here, and mixing
them up is the most common way to waste an afternoon:

| What | What it is | How long it takes |
|------|-----------|-------------------|
| **The bitstream** | The FPGA fabric: the CPU, the UART, the SRAM controller. A `.bit` file produced by ISE. | ~3-10 min to build, seconds to load |
| **The firmware** | The RISC-V program the CPU runs. A `.hex`/`.bin` produced by gcc. | ~1 s to build, ~1 s to upload |

The firmware normally lives *inside* the bitstream, as the initial
contents of the block RAM. That means changing one line of C would cost
a full re-synthesis — which is why this design also ships a **serial
bootloader**. Load the bootloader into the fabric once, then push new
firmware over the same USB serial port you use for the console.

---

## 0. What you need

| Tool | Why | Notes |
|------|-----|-------|
| Xilinx ISE 14.7 | Spartan-6 is not supported by Vivado — 14.7 is the last release that targets it | the free WebPACK licence covers the LX9 |
| `riscv64-unknown-elf-gcc` | builds the firmware | must support `-march=rv32imac` |
| `iverilog` | runs the simulations | optional, but run them before you burn a bitstream |
| `openFPGALoader` **or** `xc3sprog` | loads the bitstream over the on-board FT2232H | iMPACT does not speak FT2232 JTAG |
| `pyserial` | the firmware uploader and the console | `pip install pyserial` |

Source the ISE environment before anything that calls `xst`/`bitgen`:

```bash
source /opt/Xilinx/14.7/ISE_DS/settings64.sh
```

### Which serial port?

The FT2232H presents **two** interfaces. Channel A is the JTAG
programmer, channel B is the UART wired to `p104`/`p105`. On Linux they
come up as a pair, so the UART is almost always the *second* one:

```bash
ls -l /dev/serial/by-id/
# ...-if00-port0  -> ttyUSB0   channel A, JTAG
# ...-if01-port0  -> ttyUSB1   channel B, UART   <- this one
```

Everything below assumes `/dev/ttyUSB1`; pass `PORT=...` to the Makefile
if yours differs.

---

## 1. Path A — firmware baked into the bitstream

The straightforward route. Use it for a finished program, or when you do
not want a bootloader occupying the low 2 KB of RAM.

```bash
cd spartan6

make firmware          # sw/hello.c -> sw/hello.hex
make bit               # ISE: synthesise, place, route, bitgen
make prog              # load syn/s6_top.bit onto the FPGA
make term              # watch the output
```

`s6_top` passes `MEM_INIT = "../sw/firmware.hex"` down to `s6_ram`, whose
`$readmemh` XST turns into the block RAM's INIT strings. So the program
is in the fabric before the first clock edge — there is no boot ROM, no
copy loop and no flash to wait for.

Two synthesis front-ends are provided and produce the same bitstream:

```bash
./syn/build_ise.sh     # headless: xst, ngdbuild, map, par, trce, bitgen
cd syn && xtclsh build.tcl   # builds s6_top.xise, then runs the flow
```

Use the Tcl one if you also want to open the project in the ISE GUI
afterwards (`ise syn/s6_top.xise`). Read `syn/s6_top.syr` for the area
numbers and `syn/s6_top.twr` for whether the 48 MHz clock actually
closed.

> **If MEM_INIT is not found**, check the working directory: `$readmemh`
> resolves the path relative to wherever synthesis was launched, and both
> scripts launch it from `spartan6/syn/`.

---

## 2. Path B — the serial bootloader (recommended while developing)

Put `sw/boot.c` in the fabric once. After that, changing firmware is a
one-second serial transfer, no ISE involved.

### One-time: build a bitstream containing the bootloader

```bash
cd spartan6
make boot                                   # -> sw/boot.hex (about 700 bytes)
```

Point the top level at it, either by editing the default in
`rtl/s6_top.v`:

```verilog
parameter MEM_INIT = "../sw/boot.hex"
```

or by copying it over the name the default already uses:

```bash
cp sw/boot.hex sw/firmware.hex
```

then:

```bash
make bit
make prog
```

The board now prints, at every reset:

```
s6boot: waiting for an image (S6LD)
```

### Every time after that

```bash
make app                                    # links hello.c at 0x800
make upload PORT=/dev/ttyUSB1               # sends it and opens the console
```

or by hand:

```bash
LDSCRIPT=sw/link_app.ld NAME=myapp ./sw/build.sh sw/myapp.c
python3 tools/s6load.py -p /dev/ttyUSB1 build/myapp.bin --term
```

Programs uploaded this way **must** be linked with `sw/link_app.ld`
(origin `0x0800`), because the bootloader keeps the low 2 KB. A program
built with the ordinary `sw/link.ld` starts at 0 and would overwrite the
bootloader mid-download; `s6load.py` will not stop you, but the board
will answer `B` and refuse anything that reaches its stack.

To run a different image, press the reset button and upload again.

### Why this works at all

Most small soft cores are Harvard: instructions come from a ROM the CPU
cannot write. This one has a single **true dual-port** block RAM — port A
is the fetch port, port B is the data port, one array behind both. A
store really does become an instruction, which is also why this core
passes `rv32ui-fence_i` while the Harvard cores in the parent tutorial
cannot.

### The wire protocol

If you would rather script it yourself, it is eight bytes of header and
a checksum:

| Direction | Bytes | Meaning |
|-----------|-------|---------|
| host → board | `53 36 4C 44` | the magic `S6LD` |
| board → host | `R` | ready, send the header |
| host → board | `u32` length | payload size, little endian |
| host → board | `u32` entry | load address == entry point |
| host → board | payload | `length` bytes |
| host → board | `u32` checksum | sum of the payload bytes, mod 2³² |
| board → host | `K` | checksum matched, jumping to `entry` |
| board → host | `E` | checksum mismatch, nothing ran |
| board → host | `B` | the image would overrun the bootloader, refused |

`tb/s6_boot_tb.v` runs this whole exchange in simulation, so you can
debug a host-side change without touching hardware.

---

## 3. Making the board boot on its own

Both paths above configure the FPGA over JTAG, which is lost at power
off. To make it survive, write the bitstream to the board's QSPI flash:

```bash
openFPGALoader -c ft2232 -f syn/s6_top.bit        # -f = write to flash
```

or with xc3sprog, which needs the Spartan-6 SPI bridge bitstream:

```bash
xc3sprog -c ft2232 -I/usr/share/xc3sprog/bscan_spi_xc6slx9.bit \
         syn/s6_top.bit:w:0:BIN
```

The FPGA then loads itself from flash at power-up. A bitstream containing
the *bootloader* will still sit and wait for a serial upload; a bitstream
containing your *application* will just run it — which is what you want
for a finished board.

> Confirm the cable and flash arguments against your board's own tooling
> (`Tools/` in the Posedge One repository) before writing flash. Loading a
> bitstream over JTAG is harmless and reversible; writing flash is the
> step worth double-checking.

---

## 4. Advanced — patching firmware into an existing .bit

ISE ships `data2mem`, which rewrites block RAM contents inside a finished
bitstream without re-running synthesis. `ngdbuild -bm` emits a
`s6_top_bd.bmm` describing where the memory ended up, and then:

```bash
data2mem -bm syn/s6_top_bd.bmm -bt syn/s6_top.bit \
         -bd build/hello.elf -o b syn/s6_top_new.bit
```

This is faster than a re-synthesis and slower than the bootloader, and it
depends on the BRAM instance names XST happens to choose. Reach for it
only if you cannot spare the 2 KB the bootloader costs.

---

## 5. The serial console

115200 baud, 8 data bits, no parity, 1 stop bit, no flow control.

```bash
make term                       # tools/s6load.py --term
picocom -b 115200 /dev/ttyUSB1  # or your terminal of choice
screen /dev/ttyUSB1 115200
```

The firmware asks the hardware what its clock is (SYSCON `0x2000_0004`)
and computes the divisor from that, so the baud rate stays right even if
you re-synthesise the PLL to a different frequency.

---

## 6. When it does not work

**Nothing on the terminal.**
`uart_tx` (`p104`) must go to the FT2232's *receive* line. If the channel
is configured for FT245 async-FIFO mode instead of UART mode, `p104`/
`p105` belong to the FIFO and no serial data will ever appear — the two
personalities share the same FPGA pins. Check the FT2232 EEPROM
configuration first.

**Garbled characters, roughly the right rate.**
A clock/baud mismatch. `CLK_HZ` on `s6_soc` must equal what
`s6_clkgen` actually produces. The defaults are 24 MHz in, `MULT=32`,
`DIV=16`, so 48 MHz out; change one and you must change the other.

**Garbled characters, wildly wrong rate.**
The PLL did not lock, and the design is running off something unexpected.
Check `syn/s6_top.twr` and the `LOCKED` output.

**`s6load.py` reports "no 'R' from the bootloader".**
The board is running an application, not the bootloader. Press reset.
If it still does not answer, the bitstream does not contain `boot.hex`.

**The LED never blinks.**
`user_led` is GPIO bit 0. If the CPU trapped at reset it never gets
there — the most likely cause is a firmware image larger than
`MEM_WORDS * 4`, which `sw/build.sh` will have refused to pad, so check
the build output.

**Timing not met in `s6_top.twr`.**
Lower the clock (raise `DIV` in `s6_clkgen`, and lower `CLK_HZ` on
`s6_soc` to match) or set `FAST_FETCH = 0` on the core. That inserts a
separate FETCH state, which takes the next-PC mux out of the block RAM
address path and costs about one extra cycle per instruction.
