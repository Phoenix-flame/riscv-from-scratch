# Step 56 — Booting from flash, with no PC

Up to Step 55, every power-up of the Mitra needs a PC: `make run` over
JTAG for the bitstream and the PS program, then 3 MB over the RISC-V's
serial port. This step makes the board boot on its own, from its 16 MiB
QSPI flash, into U-Boot and Linux:

```
power on, boot mode QSPI
  Zynq BootROM ─ loads the FSBL from BOOT.BIN into OCM
  FSBL = the riscv_linux PS program
    ps7_init ─ PCAP: the PL from BOOT.BIN's bitstream ─ ps7_post_config
    DDR check ─ copies BOOT.BIN's RVBI image to DDR 0x1300_0000 ─ "run"
  RISC-V boot ROM ─ an image at 0x8300_0000: boots it after 1 s
    U-Boot ─ booti ─ Linux ─ rvfs#
```

```
make boot-mem        # the ROM boots an image in memory; a bad one, and a key, fall back to the prompt
make ps-test         # the FSBL's BOOT.BIN parser and QSPI writer, on this PC against a model
make linux-frommem   # U-Boot + Linux from memory, board configuration: nothing sent
```

Two parts can be checked here and one can't. The ROM change is simulated
fully. The PS program's `BOOT.BIN` parser and flash writer run on a PC
against a model of the controller and the flash. Its PCAP and QSPI
register sequences have not run on silicon.

## 1. The ROM: an image already in memory

The RISC-V can't reach the flash: QSPI is a PS peripheral. So the ROM
gains nothing about flash. It only learns that an image might already be
in RAM, at `BOOTMEM_ADDR = 0x8300_0000` (`sw/boot/platform.h`). That's
RAM + 48 MiB, PS DDR `0x1300_0000`.

At reset, after sizing RAM, the ROM checks for the `RVBI` magic there. If
it's there:

```
rvfs boot ROM (Step 49), hart 0
  RAM      0x80000000, 65536 KiB (probed)
  payloads [0x80004000, 0x83ffe000), DTB at 0x83ffe000
  SBI v2.0 resident: BASE TIME DBCN SRST + legacy 0.1
  image in memory at 0x83000000: booting it in 1 s, any key for the serial prompt
RVBI v1: 2 segments, entry 0x80400000, S-mode
  bootargs "console=ttyS0,115200 earlycon=sbi"
  segment 0: 0x80400000  file 601896  mem 653472
  segment 1: 0x81000000  file 2630164  mem 2630164
  data: 3232060 bytes, CRC32 0x597ac0f0 ok (239557999 cycles, 74 per byte)
  dtb: 2186 bytes, memory = <0x80000000 0x4000000>, bootargs set
  -> S-mode at 0x80400000, a0 = hart 0, a1 = dtb 0x83ffe000
```

That's the board configuration (`make linux-frommem`): U-Boot (segment 0)
and the kernel for its `booti` (segment 1), from `uboot-linux-board.rvbi`.

The image takes **the same path as one from the UART**. `get_bytes()`
replaces `rx_bytes()` with a copy from memory that folds into the same
CRC, so the header CRC is checked before anything is written. Every
segment is range-checked, then the data CRC is checked, then the DT is
fixed up and the SBI stays resident. Two things differ:

- **Segments must end below `BOOTMEM_ADDR`**, not below the DTB. Loading
  over the image while reading it would corrupt it. `payload_end` is
  `DTB_ADDR` for a serial image and `BOOTMEM_ADDR` for this one. It's set
  at run time because the DTB's place depends on the probed RAM size.
- **A key on the console within the second skips it.** The ROM drains the
  key and prints `boot> ` as before. That's the way back to the serial
  workflow without touching the board's straps.

A bad image (a CRC fails, or a segment doesn't fit) is reported and
refused, and the ROM falls back to the prompt. A board with a corrupted
flash still comes up to `boot> `. The ROM grew from 12,200 to 12,820 bytes
of its 16 KiB.

**What it costs.** Checking and copying the image runs at 74 cycles a
byte (the CRC is computed bit by bit). For U-Boot + Linux, 3.2 MB, that's
240M cycles: **4.8 s at 50 MHz**, against 4.7 minutes for the same image
at 115200. A 16-entry CRC table would roughly halve it. It's a candidate
for later; nothing else waits on it.

### Tests

`make boot-mem` (`rvboot test-bootmem`) preloads the DDR model at
`BOOTMEM_ADDR` and runs three cases:

```
[rvboot] ok   a valid image: booted from memory, nothing sent (50,567,854 cycles)
[rvboot] ok   one bit flipped: refused, then the serial prompt (51,230,600 cycles)
[rvboot] ok   a key within the second: the serial prompt (899,024 cycles)
BOOTMEM: ALL PASS
```

The valid image is `libc_demo`. Its run is checked as in `make boot`.
The bit is flipped in its data, so the ROM copies all of it, rejects the
data CRC, and then has to accept a serial image. The key is sent during
the second, and a serial image follows.

`make linux-frommem` (`rvlinux run --frommem --uboot --board`) is the
board as it will boot from flash. It uses the board ROM, 115200 baud, and
64 MiB behind a 64-bit HP0-shaped port. All of `uboot-linux-board.rvbi`
sits at `0x8300_0000`, and the bench sends nothing but the shell commands.
The checks are those of `make linux-uboot`, plus the ROM's two lines
above:

```
[rvlinux] halted, exit code 0, 598,690,566 cycles in all
[rvlinux]   241,208,579 cycles: the ROM checking and copying the image (3,232,060 bytes)
[rvlinux]   the shell prompt at cycle 547,504,135 (from reset, nothing sent)
[rvlinux]   7 commands typed; 22 output checks
LINUX: ALL PASS
```

That's the simulator configuration (`rvlinux run --frommem --uboot`). The
board configuration's run is recorded in the PR.

`make boot` and `make boot-board` pass unchanged on all six memory
configurations. None of them has anything at `0x8300_0000` (RAM there is
zero, or absent).

## 2. The FSBL: the PS program, a second way

`sw/linux/board/ps/main.c` is still the program `make run` loads over
JTAG. It reads the boot mode (`SLCR BOOT_MODE[2:0]`: 0 JTAG, 1 QSPI) and
does the extra work only in QSPI mode:

| | JTAG mode (`make run`) | QSPI mode (power-up) |
|---|---|---|
| who loaded it | OpenOCD, into OCM | the BootROM, from `BOOT.BIN` |
| `ps7_init` | yes | yes |
| the PL | already programmed over JTAG | programmed from `BOOT.BIN` through PCAP |
| `ps7_post_config`, `RVFS`, DDR check | yes | yes |
| `0x1300_0000` | cleared, so a warm `make run` after a QSPI boot doesn't boot a stale image | the RVBI image from `BOOT.BIN` |
| flash | reports what it holds | — |
| then | serves `rvboot flash` on UART0 | the same |

### Reading `BOOT.BIN` (`bootbin.c`)

The BootROM loads only the first partition, the FSBL. The FSBL finds the
rest. The layout below is what Antmicro's `mkbootimage` writes (its
`src/arch/zynq.c`, `src/bootrom.c`), and it matches Xilinx's `bootgen`:

| where | what |
|---|---|
| `0x020`, `0x024` | `0xaa995566`, `"XNLX"` |
| `0x098` | byte offset of the image header table; its word 1 is the partition count |
| `0x09c` | byte offset of the partition headers, 64 bytes each |
| header word 1 | the partition's length in words |
| header word 5 | its offset from the start, in words |
| header word 6 | attributes; bits 6:4 = 2 means the PL |
| header word 15 | `~` the sum of words 0–14 |

The bitstream is the partition destined for the PL. The RISC-V's image is
the first other partition that starts with `RVBI` and whose header CRC
checks. Every offset is checked against the size. Only aligned word loads
and byte loads are used: with the MMU off, an unaligned load faults, so
the build also passes `-mno-unaligned-access`.

### The PL from the PS (`pcap.c`)

This is the sequence U-Boot's `zynqpl` driver uses:

1. assert the fabric resets and set the level shifters to PL→PS only;
2. unlock the DevC, select PCAP, and clear the loopback;
3. pulse `PROG_B` and wait for `INIT` to fall, then rise;
4. one DMA to `0xffffffff`, the source's bit 0 marking it as the last;
5. wait for `DMA_DONE`, then `PCFG_DONE`.

`ps7_post_config()` then opens the level shifters and releases the
resets. The bitstream is copied to PS DDR `0x0100_0000` first, so the DMA
reads DDR rather than the linear flash window. `mkbootimage` stores the
bitstream's words byte-swapped, so the sync word reads `0xaa995566` and it
goes to PCAP as is. `pcap_order()` checks that, and swaps when copying if
a tool did otherwise.

### The flash (`qspi.c`)

**Reading** uses linear mode: fast read (`0x0b`, one dummy byte) at
QSPI_REF_CLK / 8 = 25 MHz, single-bit. Every SPI NOR part supports that,
and it needs no feedback clock (MIO 8 is a GPIO on this board). Each
32-bit load is one command, so roughly 1.4 MB/s. Copying a 2 MB bitstream
and the 3.2 MB image is an estimated 4 s.

**Writing** uses I/O mode, with manual chip select and manual start:

- write enable;
- a 64 KiB block erase (`0xd8`);
- page programs (`0x02`) of 128 bytes, so a command (1 + 32 words) never
  overfills the 63-word FIFOs;
- a status-register poll after each command;
- a read-back through linear mode at the end.

### `rvboot flash`

The flash has to be written by something, and without Vivado nothing in
the toolchain does it. `openFPGALoader` can't: the flash hangs off the PS,
not the PL. So the PS program writes it itself.

```
tools/rvboot flash /dev/ttyUSB1 BOOT.BIN     # the CH340 (UART0), with make run done
```

The protocol:

1. The host sends `RVFLASH1`, the length and a CRC-32.
2. The PS answers `flash: receiving N bytes` and takes the file into PS
   DDR `0x0200_0000`.
3. The PS writes nothing unless the CRC matches and the file parses as a
   `BOOT.BIN` with both payloads. Then it erases, writes and reads back.
4. It prints `flash: done, …`, or `flash: FAILED: <why>`.

That takes about 7 minutes at 115200. A wrong or partial file never
reaches the flash. Even a bad flash can't lock you out: JTAG boot mode
ignores the flash, and the ROM prompts if the image is bad.

### `make ps-test`

`sw/linux/board/ps/test/` builds `bootbin.c` and `qspi.c` for this PC.
`hw_rd()`/`hw_wr()` (`zynq.h`) land in a model of the QSPI controller as
UG585 describes it, with a 16 MiB SPI NOR behind it. The flash is strict
about write enable, about commands while it's busy, and about the 256-byte
page wrap, and programming only clears bits. `test/mkbootbin.py` writes a
`BOOT.BIN` laid out as `mkbootimage` lays one out: the offsets above, the
64-byte alignment, and the byte-swapped bitstream with its NOOP.

```
ok   parse: 3 partitions, bitstream 100056 bytes, RVBI 227854 bytes, data CRC good
ok   no width word: refused (no boot header (0xaa995566, "XNLX" at 0x20))
ok   a partition header changed: refused (a partition header's checksum is wrong)
ok   an RVBI header bit flipped: refused (no RISC-V image (...))
ok   cut short: refused (a partition lies past the end)
ok   a few bytes: refused (too short for a boot header)
ok   erased flash: refused (no boot header (0xaa995566, "XNLX" at 0x20))
ok   write: 363904 bytes, 6 block erases, 2843 page programs, read back
ok   boot from flash: found both payloads through the linear map
ok   JEDEC ID 0xef4018 (16 MiB)
ok   write of 363901 bytes (not a multiple of 4)
ok   a flash that ignores write enable: refused (the flash ignores write enable (...))
PS-HOST: ALL PASS
```

The model catches the mistakes it was built for. Each of these breaks the
test:

- dropping the write enable before page programs;
- 256-byte chunks, which overflow the FIFO;
- the address bytes in the wrong order.

What it can't show is that the silicon agrees with this reading of UG585.
`mkbootimage` itself wasn't run here: building it from source was blocked
in this environment. Its layout was taken from its source.

The PS program builds with `arm-none-eabi-gcc` against the board's Vivado
`ps7_init`. That's 19 KB loaded into OCM (the FSBL limit is 192 KB), with
no library calls.

## 3. Making `BOOT.BIN`

`make linux-oz OZ=...` now also writes `projects/riscv_linux/boot.bif`, and
copies `uboot-linux-board.rvbi` (or `linux-board.rvbi` if U-Boot isn't
built) to `fw/boot.rvbi`, which git ignores:

```
the_ROM_image:
{
    [bootloader] projects/riscv_linux/ps/build/riscv_linux.elf
    build/riscv_linux/riscv_linux.bit
    projects/riscv_linux/fw/boot.rvbi
}
```

```bash
docker compose run --rm oz make -C projects/riscv_linux/ps
docker compose run --rm oz make bit PROJECT=riscv_linux
docker compose run --rm oz mkbootimage projects/riscv_linux/boot.bif BOOT.BIN
```

`docs/mitra-board-guide.md` section 10 has the whole procedure on the
board.

## What's verified, and what isn't

| | |
|---|---|
| the ROM booting from memory: valid, corrupt, key | **simulated**, `make boot-mem` |
| U-Boot + Linux from memory on the board configuration | **simulated**, `make linux-frommem` |
| `BOOT.BIN` parsing, flash erase/program/verify | **on a PC against a model**, `make ps-test` |
| `rvboot flash` against a fake PS on a pseudo-terminal | passed once, while developing; not committed as a test |
| PCAP, the QSPI controller, the BootROM loading this FSBL | **not run**: needs the board |
| the Mitra's boot-mode switch | see the board's schematic. UG585 table 6-4: MIO[5:3] = `000` JTAG, `100` QSPI |
