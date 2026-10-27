# Step 55 — U-Boot in front of Linux

Step 49's boot ROM is a loader, not a bootloader. It takes one image over
the UART, checks it and starts it, and offers nothing to interact with.
U-Boot gives the machine what a board usually has:
- a prompt;
- an environment with `bootcmd` and `bootargs`;
- `md`/`mw`, `fdt`, `bdinfo`;
- loading over serial (`loady`);
- `booti` for a Linux `Image`.

Mainline U-Boot v2024.10 runs here unmodified. The ROM starts it in
S-mode like any payload, and it uses the ROM's resident SBI and device
tree.

```
make uboot          # fetch (pinned, hash-checked) + build U-Boot, and its images
make linux-uboot    # U-Boot autoboots Linux; the shell is checked as in make linux
```

## The build

`tools/rvlinux uboot` fetches `v2024.10`, commit `f919c3a889f0`, into
`third_party/u-boot`. It configures `qemu-riscv32_smode_defconfig` plus
`sw/uboot/uboot.config` and checks every line, as it does for the
kernel. It builds two variants out of tree, in `build/linux/uboot-<flavor>/`:

| | baud | autoboot delay | `bootargs` |
|---|---|---|---|
| `sim` | 3,125,000 | 0 | `console=ttyS0,3000000 earlycon=sbi` |
| `board` | 115,200 | 2 s | `console=ttyS0,115200 earlycon=sbi` |

They differ in the baud rate because U-Boot doesn't keep the UART as the
ROM left it. It reprograms the divisor from its own `CONFIG_BAUDRATE` and
the DT's `clock-frequency`, and it ignores `current-speed`. So an image
built for one clock-to-baud ratio prints garbage at the other.

Three things in the fragment matter:

- **No C, F or D, and no EFI**, for the same reasons as the kernel. The
  default `qemu` configuration has them all on.
- **`bootcmd = booti 0x81000000 - ${fdtcontroladdr}`**. This boots the
  kernel from where the combined image puts it, with the device tree
  U-Boot itself was given. On RISC-V, `booti` moves a kernel that sits
  in RAM to RAM base + `text_offset`, which is `0x8040_0000`, exactly
  where the Sv32 kernel must run. U-Boot itself was loaded there too, but
  by then it has relocated to the top of RAM (`0x8376_0000`).
- **`CONFIG_PRE_CONSOLE_BUFFER` off.** The first run stopped at
  `Bad Linux RISCV Image magic!`. `md.l 0x81000000` showed
  `..U-Boot 2024.10` where the kernel's header should have been. The
  `qemu` configuration puts the pre-console buffer, a 4 KiB record of
  messages printed before the console exists, at `0x8100_0000`, and
  U-Boot's banner had been written over the first 4 KiB of the kernel.
  The kernel's other 2.6 MB were intact.

The build uses the same toolchain arrangement as Step 53:
`riscv64-linux-gnu-gcc`, because the bare-metal linker can't produce
U-Boot's position-independent image, with the bare-metal toolchain's
rv32 libgcc passed in as `PLATFORM_LIBGCC`.

## The images

| file | contents | at 115200 |
|---|---|---|
| `u-boot-<flavor>.rvbi` | U-Boot (one segment, `0x8040_0000`, 602 KB) | about 52 s |
| `uboot-linux-<flavor>.rvbi` | U-Boot, then the kernel `Image` as a second segment at `0x8100_0000` | 4.7 minutes |

The combined image is one stream for the ROM, so a single
`tools/rvboot send` loads both. The ROM checks one CRC over everything
and enters U-Boot, and U-Boot's autoboot does the rest. With `loady`,
U-Boot can also take the kernel itself over YMODEM; see the
[board guide](mitra-board-guide.md#9-boot-u-boot-then-linux).

## What runs

`tools/rvlinux run --uboot` boots that pair. With `--fast`, which
`make linux-uboot` uses, the bench preloads both segments and the ROM
receives the first 4 KiB of U-Boot. On top of Step 53's six boot lines
and eleven command checks, it requires U-Boot's own:

```
U-Boot 2024.10 (...)
...
Hit any key to stop autoboot:  0
Moving Image from 0x81000000 to 0x80400000, end=806aeb88
## Flattened Device Tree blob at 82f3f610
   Booting using the fdt blob at 0x82f3f610
...
Starting kernel ...

[    0.000000] Linux version 6.18.0 (rvfs@riscv-from-scratch) ...
```

| run | result |
|---|---|
| `make linux-uboot` (`sim` U-Boot, DDR over AXI4) | LINUX: ALL PASS, 20 checks; the shell at cycle 256.7M, against 181M with the kernel booted directly. U-Boot's own start and the `booti` move cost about 75M cycles, 1.5 s at 50 MHz. |
| `rvlinux run --uboot --board` (`board` U-Boot, the board ROM, 115200, the 64-bit HP0-shaped port, the 2 s countdown) | LINUX: ALL PASS, 20 checks; the shell 343.9M cycles after the ROM started U-Boot (6.9 s at 50 MHz, 2 s of it the countdown), power-off at 412.8M; 8.5 minutes in Verilator |

The device tree Linux runs on is the ROM's. U-Boot received it in `a1`
(`OF_HAS_PRIOR_STAGE`), relocated it, and handed the relocated copy on
after setting `/chosen/bootargs` from its environment.

## Honest status

- Simulated only, like Steps 53–54.
- **The environment lives only in RAM** (`ENV_IS_NOWHERE`). Nothing
  persistent is reachable from the RISC-V: the board's QSPI and SD
  belong to the PS. `saveenv` has nowhere to go, so `bootcmd` and
  `bootargs` are compiled in. Step 56 boots the board from flash anyway:
  the PS copies U-Boot + Linux from `BOOT.BIN` into DDR for the ROM
  (`docs/56-boot-from-flash.md`); the environment still isn't saved.
- `loady` is configured but has not been tried, not even in simulation.
- U-Boot's `usbkbd`/`vidconsole` stdio entries come from the `qemu`
  defaults. They're harmless here, but they are part of why U-Boot spends
  about 5,000 cycles on each typed character. A paste at full line rate
  overflows the UART's 16-byte FIFO, so type, don't paste.

## Files

| file | |
|---|---|
| `sw/uboot/uboot.config` | the fragment |
| `tools/rvlinux` | `uboot`; `run --uboot`; the combined images (`board-image` writes the board ones too) |
| `Makefile` | `make uboot`, `make linux-uboot` |
| `docs/mitra-board-guide.md` | the bring-up guide for the board |
