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
> meets 50 MHz is unknown. Section 11 lists what to watch for. The
> "flashing" question has its own answer in section 10: today the board
> is loaded over JTAG and serial on every power-up. Nothing here is
> written to flash yet.

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
10. [Flashing: what persists, and what doesn't yet](#10-flashing-what-persists-and-what-doesnt-yet)
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

**Read nextpnr's timing report before going further.** Look for the
achieved frequency of the 50 MHz clock (`clk`). If it's below 50 MHz,
the core will misbehave at random rather than fail cleanly. See
[Troubleshooting](#11-troubleshooting).

The synthesis estimate for this design is about 88 % of the 7010's LUTs.

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
  ps7_init + ps7_post_config: ok (clocks, DDR trained, PL level shifters on)
  bitstream: RVFS
  DDR at 0x10000000..0x13ffffff: ok
  RISC-V released: its console is JM1 pin 21 (TX) / 22 (RX), 115200 8N1
  send it an image: tools/rvboot send /dev/ttyUSB0 build/linux/linux-board.rvbi
```

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

In simulation of this exact configuration, the shell came up 3.5 s after
the kernel started (6.9 s through U-Boot, including its 2 s countdown). Try:

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

## 10. Flashing: what persists, and what doesn't yet

**Today, nothing in this setup survives a power cycle.** The bitstream
and the PS program come over JTAG (`make run`), and the RISC-V's images
come over its serial port. Writing a file to flash won't change that,
for two reasons:

1. **A Zynq doesn't boot a raw bitstream from flash.** The BootROM loads
   a `BOOT.BIN` from QSPI or SD. That file holds a first-stage boot
   loader (FSBL), which runs `ps7_init`, programs the PL from a
   bitstream partition, and starts the next program. OpenZynq's
   `make flash` writes a raw `.bit`, which the BootROM ignores (its own
   `docs/03` says so). This design's PS program initialises the PS, but
   it doesn't program the PL, so it can't serve as that FSBL yet.
2. **The RISC-V can't reach the flash.** QSPI and SD are PS peripherals.
   The RISC-V's ROM boots only what arrives on its UART. U-Boot on the
   RISC-V has no driver for them either, and it couldn't reach them if
   it had one.

**What a persistent setup would take:**

| piece | what | where it can be tested |
|---|---|---|
| a. `BOOT.BIN` | the PS program as the FSBL, plus the bitstream, plus `uboot-linux-board.rvbi` as data partitions, assembled with `mkbootimage` (in OpenZynq's container; its `docs/04` shows a `.bif`) | the board |
| b. the PS program as an FSBL | after `ps7_init`: program the PL through PCAP from the bitstream partition, copy the image from QSPI (linear reads at `0xFC00_0000`) or SD into the RISC-V's DDR window, then write "run" | the board |
| c. "boot from memory" in the ROM | at reset, look for a valid image (magic, header CRC, data CRC) at a fixed DDR address. If there is one, boot it as if it had arrived over the UART; if not, prompt as now. | simulation, fully |
| d. U-Boot's environment | lives only in RAM: the board's flash isn't reachable from the RISC-V. `bootcmd` and `bootargs` are compiled in (`sw/uboot/uboot.config`). | — |

With a–c in place, the boot-mode straps go to QSPI or SD, and the board
powers up into U-Boot and Linux with no PC attached. Piece c is a small
ROM change. Pieces a and b are new PS-side code that can only be proven
on hardware. Ask, and I'll build them in that order, with c tested in
simulation first.

**What you can flash today** is OpenZynq's own PS-only material, such as
a `BOOT.BIN` with U-Boot for the Cortex-A9 (its `docs/04`). That runs
ARM Linux on the PS. It's a different computer from the RISC-V in this
guide.

## 11. Troubleshooting

| symptom | likely cause | what to do |
|---|---|---|
| `openFPGALoader --detect` finds nothing | USB passthrough or udev | OpenZynq `docs/03-jtag-and-usb.md`; look for IDCODE `0x03722093` |
| nextpnr reports `clk` below 50 MHz | the core's critical path, most likely the combinational RV32M divider | Don't run it as is. There's no clock option yet. It needs a lower core clock (an MMCM) plus the same change in `PLAT_CLOCK_HZ` and the UART divisor, so the DT, ROM and Linux agree. Ask for it. |
| place and route fails to fit or route | about 88 % of the LUTs | the known savings: the PLIC with 15 sources (≈500 LUTs), and dropping Zbc |
| the PS console is silent | the wrong `/dev/ttyUSB*`, not in JTAG boot mode, or `ps7_init` hung in DDR training | identify the CH340 by its driver (section 6); cold power-cycle in JTAG mode; `make run` again |
| `ps7_init failed: 0x…` | the PS or DDR init failed | run OpenZynq's `make ddr-test` (`docs/11`): it tests DDR with no PL involved |
| `0x40000000 reads 0x…, not RVFS` | the PL isn't this bitstream | `make run` programs the PL first; check that `make bit` produced `build/riscv_linux/riscv_linux.bit` |
| `DDR check FAILED` | DDR misbehaves from the PS side | `make ddr-test` in OpenZynq; the RISC-V is deliberately left in reset |
| LED2 dark after `RISC-V released` | no 50 MHz clock (U18), or the PL is unhealthy | check the bitstream and timing; `make run` again |
| LED2 blinks but there's no `boot> ` | TX/RX swapped, the wrong device, a 5 V adapter, or no ground | the wiring in section 6; press K1 with a terminal open |
| garbage characters | the wrong baud rate, or a `-sim` image | 115200 everywhere; use the `-board` images |
| `error: data CRC32 …, image says …` | bytes lost on the wire | check ground; send with `rvboot send`, nothing else open on the port; press K1 and resend |
| `error: header …` before any data | the ROM saw line noise before the magic | harmless if the next image is good; the ROM resynchronises on the magic |
| Linux stops early, or random Oops/panics | timing not met, or DDR | trust the timing report; then `make ddr-test` |
| U-Boot: `Bad Linux RISCV Image magic!` | no kernel at `0x81000000` | send `uboot-linux-board.rvbi`, not `u-boot-board.rvbi`, or `loady` one first |

## 12. Reference: addresses and files

**The RISC-V's map** (`sw/boot/platform.h`, `sw/boot/rvfs-soc.dts`):

| address | what |
|---|---|
| `0x0000_1000` | boot ROM, 16 KiB, in block RAM |
| `0x0010_0000` | test device: power off, reset (LED1) |
| `0x0200_0000` | CLINT: `mtime` at 50 MHz, `mtimecmp` |
| `0x0c00_0000` | PLIC: the UART is source 10 |
| `0x1000_0000` | ns16550a UART, `reg-shift 2`; 115200 = 50 MHz / 16 / 27 |
| `0x8000_0000` | RAM: the first 16 KiB in block RAM (firmware, reserved in the DT), the rest PS DDR `0x1000_4000…` |
| `0x8040_0000` | Linux runs here (RAM + 4 MiB, a Sv32 megapage). U-Boot is loaded here too, and relocates itself to the top of RAM. |
| `0x8100_0000` | where `uboot-linux-board.rvbi` puts the kernel for `booti` |
| `0x83ff_e000` | the device tree the ROM writes, the last 8 KiB of RAM |

**The PS side:** DDR `0x1000_0000..0x13ff_ffff` belongs to the RISC-V.
`M_AXI_GP0` at `0x4000_0000`: reading it returns `RVFS`, writing bit 0
sets run; `0x4000_0004` reads back run (bit 0) and powered-off (bit 1).

**Files:**

| file | |
|---|---|
| `rtl/fpga_top_linux.v`, `constraints/openzynq_linux.xdc` | the board top and its pins |
| `sw/linux/board/ps/main.c` | the PS program |
| `sw/linux/kernel.config`, `sw/linux/busybox.config`, `sw/uboot/uboot.config` | what is built |
| `tools/rvlinux` | fetch, build, `board-image`, `uboot`, `oz-export`, `oz-sim`, `run` |
| `tools/rvboot` | `image`, `info`, `send` |
| `docs/53-linux.md`, `docs/54-linux-on-the-board.md`, `docs/55-u-boot.md` | the steps behind this guide |
