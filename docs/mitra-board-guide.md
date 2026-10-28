# Running U-Boot and Linux on the Mitra-7010: the complete guide

This guide takes the RISC-V computer of Steps 49–55 onto the Artemis Karia
**Mitra-7010** (Zynq `xc7z010`). The bitstream holds a 5-stage RV32IMA
core with an MMU, caches and its own boot ROM, and its RAM is 64 MiB of
the board's DDR3. You send it U-Boot, Linux or both over a serial cable
and get a busybox shell.

> **Status, before you spend an afternoon on it.** Everything below is
> written, built and simulated:
> - the RTL, pins and PS program;
> - the OpenZynq project;
> - the kernel, U-Boot and boot images;
> - the serial loader.
>
> Linux boots to its shell, directly and through U-Boot, on the board's
> exact configuration in simulation. **None of it has run on a real
> board yet**, and the design hasn't been placed or routed, so whether it
> meets timing on silicon is unproven. **The bitstream builds with the
> open flow** (Steps 57–58, `docs/57-fitting-the-board.md`,
> `docs/58-faster-board-core.md`). The core runs at 50 MHz from the PS's
> FCLK1, and nextpnr's post-route estimate is 51.5 MHz: a thin 2.9 %
> margin (section 11 has the fallback). A prebuilt one is in OpenZynq's
> `projects/riscv_linux/prebuilt/`. Section 11 lists what to watch for. Section 10
> makes the board boot from its QSPI flash with no PC. Its ROM side is
> simulated; its FSBL code (PCAP, QSPI) has only run against a model.
> Bring the board up over JTAG and serial first (sections 7–9).

## Contents

1. [How it fits together](#1-how-it-fits-together)
2. [What you need](#2-what-you-need)
3. [Build the software](#3-build-the-software)
4. [Generate the FPGA project](#4-generate-the-fpga-project)
5. [Build the bitstream and the PS program](#5-build-the-bitstream-and-the-ps-program)
6. [Wire the RISC-V's console](#6-wire-the-risc-vs-console)
7. [Bring the board up](#7-bring-the-board-up)
8. [Boot Linux](#8-boot-linux)
9. [Boot U-Boot, then Linux](#9-boot-u-boot-then-linux)
10. [Flashing: boot with no PC attached](#10-flashing-boot-with-no-pc-attached)
11. [Troubleshooting](#11-troubleshooting)
12. [Reference: addresses and files](#12-reference-addresses-and-files)

---

## 1. How it fits together

```
 your PC                                      Mitra-7010
 ───────                                      ───────────────────────────────────────────
 USB-C  ── J8, FT232HL USB-JTAG ────────────► PL bitstream (fpga_top_linux)  +  PS program
 USB-C  ── CH340, PS UART0 ◄──────────────── the PS program's messages
 USB-serial adapter (3.3 V) ── JM1 pins ────► the RISC-V's console: boot ROM, U-Boot, Linux

            ┌──────────────────────── xc7z010 ──────────────────────────┐
            │  PS: Cortex-A9 ──► DDR controller ◄── S_AXI_HP0 ◄──┐       │
            │        │ M_AXI_GP0 (run / ID)                      │       │
            │  PL:   ▼                                            │       │
            │   fpga_top_linux ── soc_boot: RV32IMA, M/S/U, Sv32, caches │
            │                      ROM + 16 KiB firmware RAM in BRAM     │
            └────────────────────────────────────────────────────────────┘
                                       DDR3 512 MB: RISC-V RAM = 0x1000_0000 + 64 MiB
```

Every power-up goes through the same sequence:

1. **JTAG** (`make run` in OpenZynq) programs the PL and starts a small
   program on the Cortex-A9, from on-chip RAM.
2. **The PS program** runs `ps7_init()`, which brings up the clocks and
   trains the DDR. It checks the bitstream and the DDR, then writes
   "run": the RISC-V leaves reset.
3. **The RISC-V's boot ROM** prints its banner and `boot> ` on JM1.
4. **You send an image**, Linux or U-Boot + Linux, with
   `tools/rvboot send`. The ROM checks its CRCs, writes a device tree,
   and starts it in S-mode, staying resident as the SBI.

Section 10 replaces steps 1 and 4 with the flash. The BootROM starts the
same PS program from a `BOOT.BIN`, and the program programs the PL itself
and leaves the image in DDR for the ROM.

## 2. What you need

**Hardware**

| item | notes |
|---|---|
| Mitra-7010 board | rev 4 is what OpenZynq was written against |
| 2 × USB-C cables | J8 (the on-board FT232HL USB-JTAG) and the CH340 PS console |
| a 3.3 V USB-serial adapter | CP2102, FT232R, CH340G… with **3.3 V logic levels**. A 5 V adapter can damage bank 35. |
| 3 jumper wires (female) | GND, TX and RX to header JM1 |
| the board's power supply | as the vendor specifies |

**A Linux PC.** These steps assume Ubuntu 24.04. Windows works through
WSL2 with `usbipd`; see OpenZynq's `docs/03-jtag-and-usb.md`.

**Software**

- riscv-from-scratch (this repository). It needs:
  ```bash
  sudo apt-get install -y gcc-riscv64-unknown-elf gcc-riscv64-linux-gnu \
       device-tree-compiler verilator flex bison bc rsync git make python3
  ```
  Verilator is only needed for the simulations. `gcc-arm-none-eabi` is
  optional; OpenZynq's container has its own.
- **OpenZynq** ([Phoenix-flame/OpenZynq](https://github.com/Phoenix-flame/OpenZynq)),
  with Docker and `docker compose`. Its container holds the open FPGA
  flow (Yosys, nextpnr-xilinx, prjxray, openFPGALoader, OpenOCD) and the
  ARM compiler. First-time setup is `docs/01-setup.md` there, including
  `make chipdb`, which is slow but runs once per part.
- Disk: about 2.5 GB for the Linux/U-Boot sources and build, plus
  OpenZynq's chip database.

**Board setup.** Set the boot-mode straps to **JTAG** (see the board's
schematic, `boards/mitra7010/` in OpenZynq). OpenZynq's PS programs
expect a cold power-up in JTAG boot mode.

## 3. Build the software

In riscv-from-scratch:

```bash
make boot-board                        # the board's boot ROM: 115200 baud from 50 MHz
python3 tools/rvlinux fetch            # Linux 6.18, busybox 1.36.1, musl 1.2.5 (pinned, hash-checked)
python3 tools/rvlinux build            # musl, busybox, initramfs, kernel (~2 min)
python3 tools/rvlinux board-image      # build/linux/linux-board.rvbi
make uboot                             # optional: U-Boot v2024.10 + its images (~3 min)
```

`make linux` does `fetch` and `build` too, but it then spends about 15
minutes proving the result in simulation. Run it once if you like; the
board doesn't need it.

What you get in `build/linux/`:

| file | what | send time at 115200 |
|---|---|---|
| `linux-board.rvbi` | Linux, bootargs `console=ttyS0,115200 earlycon=sbi` | 3.8 minutes |
| `uboot-linux-board.rvbi` | U-Boot at `0x8040_0000` + Linux at `0x8100_0000` in one image; U-Boot autoboots it | 4.7 minutes |
| `u-boot-board.rvbi` | U-Boot alone, to its `=>` prompt | 0.9 minutes |

All three are images for the boot ROM: a header with CRCs, segments, and
bootargs (`tools/rvboot info <file>` shows them).

## 4. Generate the FPGA project

Clone OpenZynq next to this repository, then:

```bash
make linux-oz OZ=../OpenZynq
```

This writes `../OpenZynq/projects/riscv_linux`:
- the top, `fpga_top_linux.v`, on OpenZynq's own `ps7_gp0` with
  `S_AXI_HP0` enabled;
- `soc_boot`'s RTL and the board ROM;
- the pins;
- the PS program;
- a testbench.

It then simulates that top against OpenZynq's `ps7_gp0` and must end
with:

```
[rvlinux] PASS: the board top boots over HP0
LINUX-BOARD-TOP: ALL PASS
```

Re-run it whenever you change this repository. It keeps any
`ps/ps7_init.*` you've already copied in.

## 5. Build the bitstream and the PS program

In OpenZynq, inside its container:

```bash
cd ../OpenZynq
docker compose run --rm oz make -C projects/riscv_linux/ps vivado-init
docker compose run --rm oz make bit PROJECT=riscv_linux
```

`vivado-init` copies in the board's Vivado-exported `ps7_init.c`. It's the
one known to have worked on a Mitra, and it contains the DDR training
sequence. (GenZ's `make genz` output has an empty DDR table unless you run
`make vivado-ddr`; don't use it here.)

`make bit` runs synthesis (about 50 minutes), then place and route, then
generates the bitstream: `build/riscv_linux/riscv_linux.bit`.

**Read nextpnr's timing report before going further.** The RISC-V runs on
the PS's FCLK1 at 50 MHz (Steps 57–58; the PS program sets it), and nextpnr
names that clock `clk` (`u_ps7.hp0_aclk` in older builds). Its `Max frequency` line must be above
50 MHz. The `PASS`/`FAIL` on that line is against `--freq 50`, which
nextpnr applies to every clock: FCLK0 (`aclk`, GP0's registers) runs at
100 MHz, so check its figure against 100. A core clock that misses timing
makes the core misbehave at random rather than fail cleanly. See
[Troubleshooting](#11-troubleshooting).

**What to expect (Steps 57–58).** Synthesis plus place and route take about
5 minutes for this design: 35 % of nextpnr's LUT sites, 12 % of its
flip-flops, and 51.47 MHz for the core clock with `project.mk`'s placement
seed (`--seed 18`; other seeds give 43.8–51.5 MHz, so keep it unless you
change the design, then sweep for a new one). To fit and to meet timing,
the board build has an iterative divider, a registered multiplier, its own
load/store address adder, a registered D-TLB lookup and branch redirect,
forwarding compares made a cycle early, a registered fetch-page
translation, no Zba/Zbb/Zbc/Zbs, no branch predictor, and a 50 MHz core
clock from the PS's FCLK1, set by the PS program. `docs/57-fitting-the-board.md` and
`docs/58-faster-board-core.md` have the numbers and the reasons. OpenZynq's `projects/riscv_linux/prebuilt/`
holds a bitstream built this way (`riscv_linux.bit`) and the U-Boot + Linux
image (`uboot-linux-board.rvbi`), with checksums. To use the prebuilt
bitstream instead of building one, see that directory's README.

## 6. Wire the RISC-V's console

Header **JM1** is all bank 35 at 3.3 V:

| adapter pin | JM1 pin | FPGA pin | signal |
|---|---|---|---|
| GND | 3 (or 4) | — | ground |
| RX | 21 | J18 | the RISC-V's `uart_tx` |
| TX | 22 | K19 | the RISC-V's `uart_rx` |
| VCC | — | — | **leave unconnected** |

Then plug in both USB-C cables and the adapter. Three serial devices
appear. Tell them apart by driver:

```bash
for t in /sys/class/tty/ttyUSB*; do echo "$(basename $t): $(basename $(readlink -f $t/device/driver))"; done
ls -l /dev/serial/by-id/
```

| device | driver | use |
|---|---|---|
| the FT232HL on J8 | `ftdi_sio` | JTAG. Not a console; it vanishes while OpenOCD runs. |
| the CH340 on the board | `ch341-uart` | the PS console |
| your adapter | `cp210x`, `ftdi_sio` or `ch341-uart` | the RISC-V console |

If your adapter is also a CH340 or FTDI chip, use `/dev/serial/by-id/`
names, which include the serial number, rather than guessing.

Open the PS console in a second terminal:

```bash
picocom -b 115200 /dev/ttyUSB1          # the board's CH340: substitute yours
```

## 7. Bring the board up

Cold power-up the board in JTAG boot mode, then:

```bash
docker compose run --rm oz make run PROJECT=riscv_linux
```

This halts the Cortex-A9s, programs the PL, loads the PS program into OCM
and starts it. Check each stage before going on.

**The PS console** should print:

```
riscv_linux: the PS side
  JTAG boot
  FCLK1 (the RISC-V's clock): IO PLL / 20 = 50 MHz, reads back 0x00500400
  ps7_init + ps7_post_config: ok (clocks, DDR trained, PL level shifters on)
  bitstream: RVFS
  DDR at 0x10000000..0x13ffffff: ok
  flash: no boot header (0xaa995566, "XNLX" at 0x20)
  RISC-V released: its console is JM1 pin 21 (TX) / 22 (RX), 115200 8N1
  send it an image: tools/rvboot send /dev/ttyUSB0 build/linux/linux-board.rvbi
  write BOOT.BIN to flash from here: tools/rvboot flash <this port> BOOT.BIN
```

The `flash:` line reports what the QSPI flash holds (section 10). An
empty flash, or one holding some other `BOOT.BIN`, is fine in JTAG mode.

**LED2** starts blinking: the RISC-V is out of reset.

**The RISC-V console** (open it with `picocom -b 115200 /dev/ttyUSBx` on
your adapter, or let `rvboot send` do it in the next step) shows the
ROM's banner:

```
rvfs boot ROM (Step 49), hart 0
  RAM      0x80000000, 65536 KiB (probed)
  payloads [0x80004000, 0x83ffe000), DTB at 0x83ffe000
  SBI v2.0 resident: BASE TIME DBCN SRST + legacy 0.1
boot>
```

`65536 KiB (probed)` means the ROM found its 64 MiB in DDR. Press **K1**
whenever you want a fresh `boot> `: it resets the RISC-V and nothing else.

## 8. Boot Linux

Close any `picocom` on the adapter first, then:

```bash
tools/rvboot send /dev/ttyUSB2 build/linux/linux-board.rvbi    # your adapter's device
```

```
[rvboot] waiting for "boot> " on /dev/ttyUSB2 (press K1 to restart the ROM) ...
boot>
[rvboot] sending build/linux/linux-board.rvbi: 2,630,241 bytes, about 3.8 minutes at 115200
[rvboot]  57%  1,499,136 bytes    130s
```

If the banner had already scrolled by, press K1 and it will catch the
next `boot> `. When the transfer ends, `rvboot` becomes a terminal and
you watch Linux boot:

```
RVBI v1: 1 segment, entry 0x80400000, S-mode
  data: 2630164 bytes, CRC32 0x........ ok
  -> S-mode at 0x80400000, a0 = hart 0, a1 = dtb 0x83ffe000
[    0.000000] Linux version 6.18.0 (rvfs@riscv-from-scratch) ...
[    0.000000] Machine model: riscv-from-scratch boot platform
...
[    2.17    ] Run /init as init process

rvfs: Linux 6.18.0 on riscv32, busybox ash

rvfs#
```

In simulation of this exact configuration, at the board's 50 MHz, the
shell came up about 7.5 s after reset (375M cycles, including U-Boot's 2 s
countdown). Try:

```
rvfs# uname -a
rvfs# cat /proc/cpuinfo
rvfs# cat /proc/interrupts       # the UART's interrupts through the PLIC
rvfs# matest                     # misaligned accesses, emulated by the kernel
rvfs# poweroff -f
```

`poweroff -f` ends with `reboot: Power down`: LED1 lights, and the PS
console prints `riscv_linux: the RISC-V has powered off`. Quit the
terminal with **Ctrl-]**.

## 9. Boot U-Boot, then Linux

**One image, autoboot.** `uboot-linux-board.rvbi` holds U-Boot at
`0x8040_0000` and the Linux `Image` at `0x8100_0000`:

```bash
tools/rvboot send /dev/ttyUSB2 build/linux/uboot-linux-board.rvbi
```

U-Boot starts, finds the device tree the ROM handed it, and counts down:

```
U-Boot 2024.10 (Oct 27 2026 - 09:36:35 +0000)

CPU:   rvfs,cpu-pipe-u
Model: riscv-from-scratch boot platform
DRAM:  64 MiB
Core:  13 devices, 9 uclasses, devicetree: board
Loading Environment from nowhere... OK
In:    serial,usbkbd
Out:   serial,vidconsole
Err:   serial,vidconsole
No USB controllers found
Net:   No ethernet found.

Hit any key to stop autoboot:  2  1  0
Moving Image from 0x81000000 to 0x80400000, end=806aeb88
## Flattened Device Tree blob at 82f3f610
   Booting using the fdt blob at 0x82f3f610
Working FDT set to 82f3f610
   Using Device Tree in place at 82f3f610, end 82f42e99
Working FDT set to 82f3f610
No RNG device

Starting kernel ...
```

That's the simulation of exactly this image on the board's
configuration: the board ROM, 115200 baud, the 64-bit HP0 path. The
USB, video and RNG lines are U-Boot's `qemu` defaults finding nothing,
which is harmless.

Its `bootcmd` is `booti 0x81000000 - ${fdtcontroladdr}`. `booti` moves
the kernel down to RAM + 4 MiB, where an Sv32 kernel must run, and
passes it the same device tree with `bootargs` from U-Boot's
environment. From here it's section 8 again.

**Stop at the prompt.** Press a key during the countdown to get `=>`.
Then:

```
=> bdinfo                                   # 64 MiB at 0x80000000, the boot hart, the DT
=> fdt addr $fdtcontroladdr; fdt print /soc/serial@10000000
=> printenv bootargs
=> setenv bootargs console=ttyS0,115200 earlycon=sbi loglevel=8
=> boot                                     # runs bootcmd: booti the kernel at 0x81000000
```

**U-Boot alone, the kernel by YMODEM.** Send `u-boot-board.rvbi` instead
(under a minute) and stop the countdown. It reaches `=>` with no kernel
in memory; `boot` would only say `Bad Linux RISCV Image magic!`. U-Boot
can receive the kernel itself:

```
=> loady 0x81000000
```

Then send `build/linux/Image` with YMODEM. `rvboot`'s terminal can't do
that, so quit it (Ctrl-]) and use `picocom --send-cmd "sb -vv"`: start
the transfer with Ctrl-A Ctrl-S (`sb` is in the `lrzsz` package). After
that, run `booti 0x81000000 - ${fdtcontroladdr}`. This path has not been
tested, even in simulation. The combined image above is the one that
has been.

**Note:** U-Boot reprograms the UART from its own baud setting and the
device tree's clock. The `-board` images are built for 115200, and the
`-sim` images run at 3.125 Mbaud for the simulator, so on a board a
`-sim` image prints garbage.

## 10. Flashing: boot with no PC attached

Once sections 7–9 work over JTAG and serial, the board can boot on its
own from its 16 MiB QSPI flash into U-Boot and Linux (Step 56,
`docs/56-boot-from-flash.md`). Nothing is written to flash until you run
`rvboot flash` below.

**How it boots.** A Zynq's BootROM doesn't load a raw bitstream from
flash. It loads a `BOOT.BIN`, whose first partition is a first-stage boot
loader (FSBL). Here the FSBL is the same PS program as before:

1. In QSPI boot mode, the BootROM loads it from `BOOT.BIN` into OCM.
2. It runs `ps7_init`, programs the PL from the `BOOT.BIN` bitstream
   through PCAP, and runs `ps7_post_config`.
3. It checks the bitstream ID and the DDR, as in JTAG mode.
4. It copies the `BOOT.BIN`'s RISC-V image (U-Boot + Linux) to DDR
   `0x1300_0000` and releases the RISC-V.
5. The RISC-V's ROM finds the image at `0x8300_0000`. It waits 1 s (a key
   on JM1 gets `boot> ` instead), checks the image's CRCs and boots it.
   U-Boot then autoboots Linux.

The RISC-V never touches the flash. U-Boot's environment stays in RAM, and
its `bootcmd` and `bootargs` are compiled in (`sw/uboot/uboot.config`).
`saveenv` has nowhere to go.

**What's been checked.**

- The ROM half, and U-Boot + Linux booting from memory on the board
  configuration, are simulated: `make boot-mem`, `make linux-frommem`.
- The FSBL's `BOOT.BIN` parser and its flash writer have run on a PC
  against a model of the QSPI controller and flash: `make ps-test`.
- Its PCAP and QSPI register sequences have **not run on silicon**. Expect
  this part to need debugging on the first board. That's safe: JTAG boot
  mode never reads the flash, so you can always go back to sections 7–9.

### 10.1 Build `BOOT.BIN`

Build U-Boot and the board images first (`make uboot`), then regenerate
the OpenZynq project. It now also writes `projects/riscv_linux/boot.bif`
and copies `uboot-linux-board.rvbi` to `projects/riscv_linux/fw/boot.rvbi`:

```bash
make uboot
make linux-oz OZ=../OpenZynq
```

`linux-oz` prints `projects/riscv_linux/fw/boot.rvbi:
build/linux/uboot-linux-board.rvbi, for BOOT.BIN (boot.bif)`. Then, in
OpenZynq:

```bash
cd ../OpenZynq
docker compose run --rm oz make -C projects/riscv_linux/ps vivado-init   # if not done yet
docker compose run --rm oz make -C projects/riscv_linux/ps               # the FSBL: ps/build/riscv_linux.elf
docker compose run --rm oz make bit PROJECT=riscv_linux                  # if not built yet
docker compose run --rm oz mkbootimage projects/riscv_linux/boot.bif BOOT.BIN
```

`BOOT.BIN` comes out at about 5.3 MB: the FSBL (19 KB), the bitstream
(about 2.1 MB) and the RISC-V image (3.2 MB). It must stay under 16 MiB.
Optionally, `make -C projects/riscv_linux/ps test` re-runs the parser and
flash-writer checks.

### 10.2 Write it to the flash

Use JTAG boot mode and `make run`, as in section 7:

```bash
docker compose run --rm oz make run PROJECT=riscv_linux
```

The PS console now prints two extra lines: what the flash holds, and that
it accepts a `BOOT.BIN`:

```
  flash: no boot header (0xaa995566, "XNLX" at 0x20)
  ...
  write BOOT.BIN to flash from here: tools/rvboot flash <this port> BOOT.BIN
```

Close any terminal on the PS console, then, from riscv-from-scratch, give
`rvboot flash` the **CH340's** port. That's the PS console, not the JM1
adapter:

```bash
tools/rvboot flash /dev/ttyUSB1 ../OpenZynq/BOOT.BIN
```

```
[ps] flash: receiving 5312356 bytes
[rvboot] sending ../OpenZynq/BOOT.BIN: 5,312,356 bytes, about 7.7 minutes at 115200
[rvboot] 100%  5,312,356 bytes    461s
[ps] flash: CRC ok, BOOT.BIN: bitstream 2083856 bytes, RISC-V image 3232149 bytes
[ps] flash: JEDEC ID 0x00ef4018; erasing and writing
[ps] flash: 1024 of 5187 KiB
...
[ps] flash: done, 5312356 bytes written and read back. Set the boot mode to QSPI and power-cycle.
[rvboot] flash written: set the boot mode to QSPI and power-cycle
```

The JEDEC ID tells you the flash part. The last two hex digits should be
`18` (16 MiB). The sizes above are illustrative. The PS program checks the
file's CRC, and that it's a `BOOT.BIN` holding both a bitstream and an
RVBI image, **before** it erases anything. Afterwards it reads the whole
image back. A failure prints `flash: FAILED: <why>`. Before the erase,
the flash is left as it was. During the write, what's left fails one of
the boot-time checks (the FSBL's, PCAP's or the ROM's CRCs), so write it
again. The RISC-V keeps running throughout; flashing doesn't touch its
DDR.

Run `make run` again in JTAG mode, and the PS console now reports
`flash holds a riscv_linux BOOT.BIN: bitstream … bytes, RISC-V image …
bytes (it boots with the boot mode on QSPI)`. That shows that QSPI reads
and parsing work on your board before you change the straps.

### 10.3 Boot from it

Power off, set the boot mode to **QSPI**, and power on. UG585 table 6-4
gives the boot-mode pins: MIO[5:3] = `000` for JTAG, `100` for QSPI. Find
which switch or jumpers drive them on the Mitra's schematic. Have both
consoles open. The PS console prints:

```
riscv_linux: the PS side
  QSPI boot: this is the FSBL
  FCLK1 (the RISC-V's clock): IO PLL / 20 = 50 MHz, reads back 0x00500400
  PL programmed from flash (PCAP, 2083856 bytes)
  ps7_init + ps7_post_config: ok (clocks, DDR trained, PL level shifters on)
  bitstream: RVFS
  DDR at 0x10000000..0x13ffffff: ok
  RISC-V image copied from flash to 0x13000000 (3232149 bytes)
  RISC-V released: its console is JM1 pin 21 (TX) / 22 (RX), 115200 8N1
  its ROM boots the image in 1 s; a key on its console first gets "boot> "
```

Then JM1 shows the ROM banner and `image in memory at 0x83000000: booting
it in 1 s`. After about 5 s of checking (240M cycles at 50 MHz) it
prints `data: … ok`, then U-Boot, its 2-second autoboot, and Linux to
`rvfs# ` about 7.5 s later. Expect roughly 15 s from power to shell: an
estimate from the simulated cycle counts at the board's 50 MHz, plus
the flash reads.

- **To get the serial prompt instead**, press a key on JM1 within that
  second. K1 resets only the RISC-V. By then U-Boot and Linux have
  probably reused the memory the image was in, so the ROM's CRC check
  usually fails and it prompts `boot> `. A power-cycle always boots from
  flash again.
- **To change what boots**, rebuild `BOOT.BIN` and flash it again
  (section 10.2, in JTAG mode).
- **To go back to the JTAG workflow**, set the straps to JTAG. The flash is
  ignored, and `make run` clears the image from DDR, so the ROM prompts as
  before.

## 11. Troubleshooting

| symptom | likely cause | what to do |
|---|---|---|
| `openFPGALoader --detect` finds nothing | USB passthrough or udev | OpenZynq `docs/03-jtag-and-usb.md`; look for IDCODE `0x03722093` |
| nextpnr reports the core clock (`clk`) below 50 MHz | a changed design with the old seed: placement moves this core between 43.8 and 51.5 MHz (Step 58) | Don't run it as is. Sweep nextpnr's `--seed` and keep the best in `OZ_SEED` (`tools/rvlinux`); `docs/58-faster-board-core.md` has the sweep. |
| the board runs, then crashes or corrupts data at random | the core too slow for 50 MHz on this chip: the 2.9 % margin is on an estimate | Use the 33.33 MHz build (22 % margin): in OpenZynq, `git checkout 422f1e3 -- projects/riscv_linux` restores its bitstream, ROM and PS program together. A clock of your own needs the PS program's divisor (`fclk1_init` in `ps/main.c`), `PLAT_CLOCK_HZ` and the UART divisor (`BBL_DEFS` in the Makefile) changed together, so the DT, ROM and Linux agree. |
| place and route fails to fit or route | too much logic for nextpnr-xilinx: it adds route-through LUTs on top of the ≈88 % that Yosys reports; the array dividers were the first culprit (fixed by `DIV_ITER`, Step 57) | `docs/57-fitting-the-board.md`; next savings: Zba/Zbb/Zbc/Zbs (≈2,000 LUTs, unused by the kernel), the branch predictor, the PLIC with 15 sources |
| the PS console is silent | the wrong `/dev/ttyUSB*`, not in JTAG boot mode, or `ps7_init` hung in DDR training | identify the CH340 by its driver (section 6); cold power-cycle in JTAG mode; `make run` again |
| `ps7_init failed: 0x…` | the PS or DDR init failed | run OpenZynq's `make ddr-test` (`docs/11`): it tests DDR with no PL involved |
| `0x40000000 reads 0x…, not RVFS` | the PL isn't this bitstream | `make run` programs the PL first; check that `make bit` produced `build/riscv_linux/riscv_linux.bit` |
| `DDR check FAILED` | DDR misbehaves from the PS side | `make ddr-test` in OpenZynq; the RISC-V is deliberately left in reset |
| LED2 dark after `RISC-V released` | no FCLK1 (the PS program sets it: check its `FCLK1 ... reads back 0x00500400` line), or the PL is unhealthy | check the bitstream and timing; `make run` again |
| LED2 blinks but there's no `boot> ` | TX/RX swapped, the wrong device, a 5 V adapter, or no ground | the wiring in section 6; press K1 with a terminal open |
| garbage characters | the wrong baud rate, or a `-sim` image | 115200 everywhere; use the `-board` images |
| `error: data CRC32 …, image says …` | bytes lost on the wire | check ground; send with `rvboot send`, nothing else open on the port; press K1 and resend |
| `error: header …` before any data | the ROM saw line noise before the magic | harmless if the next image is good; the ROM resynchronises on the magic |
| Linux stops early, or random Oops/panics | timing not met, or DDR | trust the timing report; then `make ddr-test` |
| U-Boot: `Bad Linux RISCV Image magic!` | no kernel at `0x81000000` | send `uboot-linux-board.rvbi`, not `u-boot-board.rvbi`, or `loady` one first |
| `rvboot flash`: `no answer on … in 5 s` | the wrong port (JM1's adapter instead of the CH340), the PS program not running, or another terminal holding the port | `make run` in JTAG mode; the CH340 is the `ch341` driver's node (section 6); close picocom |
| `flash: FAILED: CRC-32 …` | bytes lost on the PS console | nothing was written; run it again with nothing else on the port |
| `flash: FAILED: the flash ignores write enable` | the flash's block protection is set, or the QSPI wiring/clocks differ from what `qspi.c` assumes | note the JEDEC ID it printed and report it; the flash is untouched |
| QSPI boot: the PS console is silent | the BootROM didn't take the `BOOT.BIN`: the straps, or a bad image | back to JTAG mode; `make run` reports what the flash holds |
| QSPI boot: `PL: …` and a stop | PCAP failed: a bitstream for another part, or an untested register sequence | report the message; JTAG mode still works |
| QSPI boot: the PS is fine, but JM1 shows `boot> ` | the ROM refused the image (its CRC line says why), or a key arrived during its second | rebuild and reflash `BOOT.BIN`; check nothing is typing on JM1 |

## 12. Reference: addresses and files

**The RISC-V's map** (`sw/boot/platform.h`, `sw/boot/rvfs-soc.dts`):

| address | what |
|---|---|
| `0x0000_1000` | boot ROM, 16 KiB, in block RAM |
| `0x0010_0000` | test device: power off, reset (LED1) |
| `0x0200_0000` | CLINT: `mtime` at 50 MHz (the core clock), `mtimecmp` |
| `0x0c00_0000` | PLIC: the UART is source 10 |
| `0x1000_0000` | ns16550a UART, `reg-shift 2`; 115200 ≈ 50 MHz / 16 / 27 |
| `0x8000_0000` | RAM: the first 16 KiB in block RAM (firmware, reserved in the DT), the rest PS DDR `0x1000_4000…` |
| `0x8040_0000` | Linux runs here (RAM + 4 MiB, a Sv32 megapage). U-Boot is loaded here too, and relocates itself to the top of RAM. |
| `0x8100_0000` | where `uboot-linux-board.rvbi` puts the kernel for `booti` |
| `0x8300_0000` | where the ROM looks for an image at reset: PS DDR `0x1300_0000`, filled by the FSBL from flash (Step 56) |
| `0x83ff_e000` | the device tree the ROM writes, the last 8 KiB of RAM |

**The PS side:** DDR `0x1000_0000..0x13ff_ffff` belongs to the RISC-V.
The PS program uses `0x0100_0000` (the bitstream on its way to PCAP) and
`0x0200_0000` (a `BOOT.BIN` on its way to the flash). The flash is read at
`0xfc00_0000`.
`M_AXI_GP0` at `0x4000_0000`: reading it returns `RVFS`, writing bit 0
sets run; `0x4000_0004` reads back run (bit 0) and powered-off (bit 1).

**Files:**

| file | |
|---|---|
| `rtl/fpga_top_linux.v`, `constraints/openzynq_linux.xdc` | the board top and its pins |
| `sw/linux/board/ps/main.c` | the PS program, and the FSBL of `BOOT.BIN` (Step 56) |
| `sw/linux/board/ps/{bootbin,qspi,pcap}.c`, `test/` | `BOOT.BIN` parsing, the QSPI flash, PL programming; `make ps-test` |
| `sw/linux/kernel.config`, `sw/linux/busybox.config`, `sw/uboot/uboot.config` | what is built |
| `tools/rvlinux` | fetch, build, `board-image`, `uboot`, `oz-export`, `oz-sim`, `run` |
| `tools/rvboot` | `image`, `info`, `send`, `flash` |
| `docs/53-linux.md`, `docs/54-linux-on-the-board.md`, `docs/55-u-boot.md`, `docs/56-boot-from-flash.md` | the steps behind this guide |
