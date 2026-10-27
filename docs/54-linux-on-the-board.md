# Step 54 — Linux on the Mitra-7010: RAM in the PS's DDR

Step 53 boots Linux on `soc_boot` in simulation, with 64 MiB of RAM in a
DDR model over AXI4. The board build of Step 51 (`fpga_top_boot`) has
128 KiB of block RAM, all the PL has to spare, and Linux needs megabytes.
The Mitra-7010 has 512 MB of DDR3, but on the processing-system (PS)
side of the Zynq: a PL master reaches it only through one of the PS's
`S_AXI_HP` ports.

This step wires that path:
1. **A 64-bit line master.** The cache-line burst master gains a 64-bit
   mode, which is the shape of `S_AXI_HP0`.
2. **A board top.** `fpga_top_linux` puts `soc_boot` on OpenZynq's PS7
   wrapper with HP0 switched on.
3. **A PS program** that trains the DDR before the RISC-V may touch it.
4. **An export** that writes all of this into an OpenZynq checkout as a
   project.
5. **A loader** that sends the kernel to the board over a USB-serial
   adapter.

```
make linux-board            # Linux on the board's configuration, in simulation
make linux-oz OZ=<openzynq> # write projects/riscv_linux there + simulate its top
```

**Can it run on the real board now?** Everything up to the bitstream is
written and simulated. That covers the RTL, pins, PS program, project,
kernel image and loader. Linux boots to its shell on the board's exact
configuration in simulation. What has *not* happened is the part that
needs the board and OpenZynq's place-and-route toolchain, which this
environment doesn't have. Nobody has placed, routed, timed or run this
design. Those are the remaining risks, listed under
[Before you try it](#before-you-try-it).

## The path

```
RISC-V 0x8000_0000 + 64 MiB
   │  D-cache / I-cache lines (32 bytes), line_arb
   ▼
axi4_line_master  DATA_W = 64      one line = INCR burst of 4 × 8 bytes
   │  AXI3 (awlen[3:0], IDs 0)
   ▼
S_AXI_HP0  (ps7_gp0 #(.HP0_ENABLE(1)), OpenZynq)
   ▼
PS DDR controller ─► DDR3, PS address 0x1000_0000 .. 0x13ff_ffff
```

- **Width.** `axi4_line_master` takes `DATA_W = 32 | 64`. At 64 bits a
  32-byte line is four beats of size 3, two words per beat, with the
  lower address in the low half. That fits AXI3's 4-bit burst length.
  Against the stalling DDR model a line costs 17 cycles instead of 23.
  `axi4_mem` models a 64-bit port too. It checks that every burst is
  INCR, size 3, aligned and at most 16 beats.
- **`soc_boot`** passes `AXI_DATA_W` through. The rest of `MEMSYS = 2` is
  unchanged: the ROM and the firmware's 16 KiB stay in block RAM, and
  everything above goes out over the port.
- **Clock.** HP0 runs on the core's 50 MHz PL clock, so the data path
  crosses no clock domain.
- **The window.** The RISC-V's RAM starts at PS DDR `0x1000_0000`,
  256 MB into the board's 512 MB. Nothing on the PS side uses it: the PS
  program runs from OCM.
- **HP0's data width** is the PS's reset default, 64 bits. The board's
  Vivado-exported `ps7_init` leaves the AFI registers alone, which is what
  selects that default.

## Who goes first: the PS

DDR exists only after the PS has run `ps7_init()`, which sets the clocks,
trains the DDR and configures the controller. An HP0 access to an
untrained controller may never complete, and no PL reset can undo that.
The level shifters and the fabric resets come up in `ps7_post_config()`,
after training. The design doesn't rely on when the PS releases HP0's own
reset; that wasn't something I could confirm from the files. The core
waits for an explicit word from the PS program instead.

`fpga_top_linux` decodes two registers on `M_AXI_GP0` (PS address
`0x4000_0000`, clocked by FCLK0):

| offset | read | write |
|---|---|---|
| `0x00` | `0x5256_4653`, "RVFS": this bitstream | bit 0 = run (1 releases the RISC-V, 0 holds it) |
| `0x04` | bit 0 run, bit 1 the RISC-V has powered off | — |

Any other GP0 access also completes, reading 0, so no PS access can hang
the bus. The core's reset is K1, or `run` = 0, or HP0 still in reset,
through a 3-flop synchroniser. LED2 stays dark while the core is held.

The PS program (`sw/linux/board/ps/main.c`) is OpenZynq's OCM-resident
pattern, the same as `ddr_test`'s. In order, it:
1. runs `ps7_init()` and `ps7_post_config()`;
2. reads the ID word, to confirm the PL holds this bitstream;
3. does a quick DDR check inside the RISC-V's window: walking ones, and
   address-in-data over 64 KiB at each end;
4. writes run = 1;
5. reports on UART0 (the on-board CH340), including when the RISC-V
   powers off.

It builds with `arm-none-eabi-gcc` against OpenZynq's `startup.S`,
`linker.ld` and the board's Vivado-exported `ps7_init.c`, into 2.2 KB of
code.

## The OpenZynq project

`make linux-oz OZ=<checkout>` writes `projects/riscv_linux` there:

| file | |
|---|---|
| `project.mk` | `TOP = fpga_top_linux`; synthesis with OpenZynq's `rtl/ps7_gp0.v` and `rtl/axi3_to_axilite.v`; `--freq 50` |
| `fpga_top_linux.v`, `rtl/*.v` | the top and `soc_boot`'s 22 files |
| `riscv_linux.xdc` | `constraints/openzynq_linux.xdc` |
| `fw/rom.hex` | the board ROM (115200 baud from 50 MHz) |
| `ps/` | `main.c`, `Makefile`, plus OpenZynq's `startup.S`, `linker.ld` and `xil_io.h` |
| `tb_fpga_top_linux.v`, `sim/` | `make sim`: the top, `tb/ps7_hp0_model.v` as the PS, a DDR model, a bad image, then `libc_demo` |

It refuses to overwrite a project it didn't write (`--force` overrides
that), and it keeps a `ps/ps7_init.*` you've already copied in. It also
writes `build/linux/linux-board.rvbi`, the kernel with
`console=ttyS0,115200` bootargs. Then it runs `rvlinux oz-sim`, the same
testbench under Verilator against the checkout's own `ps7_gp0`.

**Pins** (`constraints/openzynq_linux.xdc`): the same as the Step 51
board build, plus UART RX, which until now was a placeholder:

| signal | pin | where |
|---|---|---|
| `clk` | U18 | 50 MHz PL oscillator |
| `resetn` | U19 | K1 |
| `uart_tx` | J18 | JM1 pin 21, to the adapter's RX |
| `uart_rx` | K19 | JM1 pin 22 (bank 35, 3.3 V), from the adapter's TX |
| `led`, `led2` | R19, V13 | powered off; heartbeat once released |

Ground goes to JM1 pin 3 or 4, and the adapter must be 3.3 V. The PS side
(DDR, FCLK0, GP0, HP0) needs no pins.

## Loading a board: `rvboot send`

```
tools/rvboot send /dev/ttyUSB0 build/linux/linux-board.rvbi
```

It sets the port to raw 8N1 at 115200 and waits for `boot> ` (press K1 to
get a fresh one). Then it sends the image with a progress line: 2.6 MB
takes 3.8 minutes. After that it becomes a terminal, and Ctrl-] quits.
It needs no pyserial, just `termios`. Against a pseudo-terminal playing
the ROM, it delivered both `libc_demo.rvbi` and the 2,630,241-byte
kernel image byte-exact.

## What runs in simulation

| run | what it exercises | result |
|---|---|---|
| `make axi4-line` | the line master at 32 and 64 bits against the stalling slave | ALL PASS, 0 protocol errors |
| `make boot` | the 244-line transcript on ideal, BRAM, DDR and now **ddr64** | ALL PASS |
| `make boot-board` | the board ROM on BRAM, and on **board-ddr**: 64 MiB over the 64-bit port | ALL PASS |
| `rvlinux oz-sim` | `fpga_top_linux` with OpenZynq's own `ps7_gp0`; the PS model reads "RVFS", writes run; a bad image is rejected; `libc_demo` runs from DDR | PASS: 1,326 HP0 reads + 456 writes, no protocol errors, no HP0 use before the PS, the core never out of reset early |
| ... with `+NO_RUN` | the PS never says run | as it must: no output, no HP0 traffic |
| `make linux-board` | Linux 6.18 on the board configuration: the board ROM, 115200 baud, the 64-bit port (kernel preloaded) | LINUX: ALL PASS, all 17 checks; the shell 174.5M cycles after kernel entry (3.5 s at 50 MHz), power-off at 244M cycles, 5 minutes in Verilator |
| OpenZynq `make sim PROJECT=riscv_linux` | the exported project under Icarus | builds and runs, at about 3,700 cycles a second, so the 20.9M-cycle sequence takes about 1.5 hours; not run to completion here. The same testbench and sources pass under Verilator as `rvlinux oz-sim` (above). |
| OpenZynq `make synth PROJECT=riscv_linux` | Yosys 0.33 for the xc7z010 | 14,589 LUTs of logic + ~990 as distributed RAM (88 % of 17,600 together), 7,997 FFs, 8 RAMB36 of 60, 12 DSP48, the PS7; as in Step 52's run, ABC aborted one pass, so this is likely an upper bound |

## Before you try it

What's needed, in order:

1. **OpenZynq's toolchain.** The project's Docker image provides Yosys,
   nextpnr-xilinx and prjxray (`docker compose run --rm oz`). None of it
   ran here.
2. **`make linux-oz OZ=...`** from riscv-from-scratch. That also needs
   `make linux` once, for the kernel.
3. In OpenZynq: **`make -C projects/riscv_linux/ps vivado-init`**. This
   copies in the board's Vivado-exported `ps7_init`, the only one known to
   have worked on a Mitra. GenZ's version has an empty DDR table unless
   `make vivado-ddr` fills it.
4. **`make bit PROJECT=riscv_linux`**, then **`make run PROJECT=riscv_linux`**.
   UART0 should report `ps7_init ... ok`, `bitstream: RVFS`, the DDR check
   and `RISC-V released`, and LED2 should start blinking.
5. **A 3.3 V USB-serial adapter on JM1**, then `tools/rvboot send`. The
   ROM banner should report `65536 KiB (probed)`, and the kernel then
   boots to `rvfs# `.

What could go wrong, from most to least likely:

- **Timing.** Nothing here has been placed or routed. The core has a
  combinational RV32M divider that Step 45 already flagged as the likely
  critical path at 50 MHz, and Linux needs M. If 50 MHz doesn't close,
  the fallback is a slower core clock from an MMCM. The DT's 50 MHz
  (`PLAT_CLOCK_HZ`) and the UART divisor would have to follow, so it is a
  rebuild, not a pin change.
- **Fit.** Synthesis puts it at about 88 % of the 7010's LUTs: 14,589 as
  logic and about 990 as the caches' distributed RAM. That's 448 more
  logic LUTs than Step 52's all-block-RAM build, for the GP0 bridge, the
  64-bit master and the wrapper. Routing at that density is untested. If
  it fails, the cheapest savings are already known:
  - `SOURCES = 15` on the PLIC, about 500 LUTs (Step 50);
  - dropping Zbc, since the kernel is built without it.
- **DDR and HP0 on this board.** OpenZynq's README lists both as not yet
  validated on hardware. The PS programs that have run on a Mitra used
  the same Vivado `ps7_init`, but none of them used DDR from the PL.
  `ddr_test` (OpenZynq) is the first thing to run if the DDR check here
  fails.
- **My PS7 model.** The simulation's PS stands in for the real one, and
  its behaviour is my reading of the Zynq documentation: HP0 64 bits wide
  by default, IDs echoed, one transaction per direction. Real HP0 ports
  reorder nothing for a single ID, but they have their own latency and
  FIFO behaviour.
- **The speed grade** (`-1` or `-2`, see OpenZynq's `ps7-profile.md`)
  changes the timing database.

## Takeaway

The address map made this small. The RISC-V's RAM was already "whatever
answers AXI at `AXI_OFFSET`", so moving it from a model to the PS's DDR
came down to three things: the port's width, a clock, and an order of
events. The order is the part that's easy to get wrong on hardware. The
PL can be configured before the DDR exists. So the core waits for an
explicit run from the program that trained the memory, instead of
inferring readiness from a reset line.

## Files

| file | |
|---|---|
| `rtl/axi4_line_master.v` | `DATA_W = 64`: 4-beat, size-3 bursts |
| `rtl/soc_boot.v` | `AXI_DATA_W` |
| `rtl/fpga_top_linux.v` | the board top: `ps7_gp0` + HP0, the GP0 run/ID registers, the reset gate |
| `constraints/openzynq_linux.xdc` | its pins, UART RX on K19 |
| `sw/linux/board/ps/main.c`, `Makefile` | the PS program |
| `tb/axi4_mem.v`, `tb/axi4_line_tb.v` | 64-bit beats and AXI3 checks; the 64-bit run |
| `tb/boot_tb.v`, `tools/rvboot` | `AXI_DATA_W`; the `ddr64` and `board-ddr` variants; `rvboot send` |
| `tb/ps7_hp0_model.v`, `tb/fpga_top_linux_tb.v` | the PS7 model and the board-top testbench |
| `tools/rvlinux`, `Makefile` | `run --board`, `board-image`, `oz-export`, `oz-sim`; `make linux-board`, `make linux-oz` |
