# Step 53 — Linux, from source, with `make linux`

Steps 49–52 gave `soc_boot` what a kernel expects of a machine:
- the boot protocol, a device tree and an SBI;
- a PLIC, precise access faults and Svade A/D bits;
- megabytes of RAM behind caches with a coherent `FENCE.I`;
- misaligned accesses that trap.

This step puts an actual kernel on it, and makes that reproducible
from the repository with one command:

```
make linux         # fetch, build, boot over the serial line, check (~15 min)
make linux-fast    # the same, with the kernel preloaded into the DDR model (~5 min)
```

What runs is mainline Linux 6.18, a busybox 1.36.1 shell and musl
1.2.5, all built from source for RV32IMA with no FPU and no C extension.
It boots on `soc_boot` with 64 MiB of DDR over AXI4, in Verilator. The
boot ROM receives the kernel over the UART and checks its CRC. It fills
in the device tree and enters the kernel in S-mode, and stays resident
as the SBI. The bench then types seven commands at the shell and checks
what comes back:

```
rvfs: Linux 6.18.0 on riscv32, busybox ash

BusyBox v1.36.1 (...) built-in shell (ash)

rvfs# uname -a
Linux (none) 6.18.0 #3 ... riscv32
rvfs# cat /proc/cpuinfo
isa		: rv32ima_zicntr_zicsr_zifencei_zihpm_zaamo_zalrsc_zba_zbb_zbc_zbs
mmu		: sv32
uarch		: rvfs,cpu-pipe-u
rvfs# cat /proc/interrupts
  1:        136 SiFive PLIC  10 Edge      ttyS0
  5:        876 RISC-V INTC   5 Edge      riscv-timer
rvfs# echo $((6*7)) > /tmp/x; cat /tmp/x
42
rvfs# matest
lw @+1 = 14131211, lh @+3 = 00001413, lhu @+7 = 00001817, sw @+9 -> d4 c3 b2 a1: ok
amoadd.w @+2 in a child: SIGBUS  ok
rvfs# poweroff -f
[    4.079009] reboot: Power down
```

## What `make linux` does

`tools/rvlinux` runs three steps; `all` runs them in order.

**fetch** clones three trees at pinned tags into `third_party/`, which
is gitignored, as riscv-tests already is:

| | tag | commit | from |
|---|---|---|---|
| Linux | `v6.18` | `7d0a66e4bb90` | `github.com/torvalds/linux` |
| busybox | `1_36_1` | `1a64f6a20aaf` | `github.com/mirror/busybox` |
| musl | `v1.2.5` | `0784374d5614` | `github.com/kraj/musl` |

Each commit hash is checked after the clone, so a mirror can't hand over
anything else. `RVLINUX_LINUX_URL`, `RVLINUX_BUSYBOX_URL` and
`RVLINUX_MUSL_URL` switch to other mirrors, such as kernel.org,
git.busybox.net or git.musl-libc.org, and the same hashes still apply.
The Linux tree is about 2 GB even at depth 1.

**build** writes everything under `build/linux/`. Building from scratch
takes about 2 minutes on 4 cores; a rebuild with nothing changed takes
5 seconds. The Linux source tree is never written to: everything goes to
`O=build/linux/kernel`.

1. **musl**, configured for `riscv32-linux-musl` with
   `-march=rv32ima_zicsr_zifencei -mabi=ilp32`. This is the soft-float
   `-sf` subarch; the core has no FPU. It is built with Ubuntu's
   `riscv64-linux-gnu-gcc`, which compiles RV32 well enough but ships no
   32-bit libgcc. The bare-metal `riscv64-unknown-elf-gcc` the rest of
   the repo uses has an `rv32im/ilp32` multilib, and that libgcc is
   linked instead.
2. **A compiler wrapper**, `build/linux/bin/rv32-musl-gcc`. It compiles
   against musl's headers and links `crt1.o`, `libc.a` and that libgcc
   statically. It stays out of `-c` and `-r` steps, because busybox
   partial-links its object directories.
3. **Kernel headers**, installed into the musl sysroot. busybox needs
   `linux/*.h`.
4. **busybox**: `allnoconfig` plus `sw/linux/busybox.config` (ash and 40
   applets, static). `LFS` is required, because musl's `off_t` is always
   64-bit.
5. **matest** (`sw/linux/matest.c`), the misaligned-access test from
   Step 52, now in user space.
6. **The initramfs list**: busybox and its applets as symlinks,
   `sw/linux/init`, `matest`, and `/dev/console`. The kernel packs it
   uncompressed, so nothing has to be decompressed on a 50 MHz-class
   core.
7. **The kernel**: `tinyconfig` plus `sw/linux/kernel.config`, applied
   with `scripts/config` and then `olddefconfig`, twice, because a
   choice can need its menu's option first. Afterwards every line of the
   fragment is checked against the final `.config`, and the build stops
   if one didn't take. Those lines are documented in the fragment. The
   ones that matter:
   - `ARCH_RV32I`, `NONPORTABLE`, no `SMP`, no `FPU`;
   - no `RISCV_ISA_C`, and no `EFI`, because EFI forces C back on;
   - no Zb\*/Zicbo\*;
   - `RISCV_EMULATED_UNALIGNED_ACCESS`, for Step 52's traps;
   - `SIFIVE_PLIC`, `SERIAL_8250` and `SERIAL_OF_PLATFORM`, earlycon on
     the SBI, and no `LEGACY_PTYS`.

**run** wraps `Image` in a boot image, using `rvboot`'s format and code,
for `0x80400000`. On Sv32 the kernel must sit on a 4 MiB megapage
boundary, and RAM + 4 MiB is the first one above the firmware. The
bootargs are `console=ttyS0,3000000 earlycon=sbi`. The run builds `rvboot`'s DDR bench and
sends the image at `boot> `. At every `rvfs# ` it types the next
command, at one key per 16,000 cycles, because a shell that echoes each
key can't keep up with a line arriving at full rate. Then it checks:
- six boot lines: the version, the machine model, the PLIC, ttyS0 as a
  16550A, `Run /init`, and the banner;
- eleven output lines from the seven commands;
- no panic, Oops or `BUG:`;
- a clean power-off.

`tb/boot_tb.v` gains three plusargs for this, all off by default, so
`make boot` is unchanged:
- `+PROMPT=` adds one more prompt to send at;
- `+TYPEGAP=` paces short chunks;
- `+PRELOAD=` `$readmemh`s RAM at `#1`, after the DDR model's own
  time-0 clear.

## Where the time goes

| | `make linux` | `make linux-fast` |
|---|---:|---:|
| the ROM receiving the image | 421,988,020 cycles (2,630,164 bytes, 160 a byte) | 655,499 (the first 4,096 bytes) |
| kernel entry → `rvfs# ` | 180,779,781 | 181,337,496 |
| everything, to power-off | 652,999,419 | 232,294,229 |
| wall time (Verilator, one core) | 14 m 05 s | 5 m 15 s |

At 50 MHz, the shell appears 3.6 s after the kernel starts. Most of
that is ordinary initcalls on a small in-order core with 2 KiB caches
over DDR latency.

An earlier build spent 5.9 s more in a single function. `initcall_debug`
traced it to `pty_init`, which was creating 256 legacy BSD pty pairs.
The fragment now turns `LEGACY_PTYS` off.

`--fast` exists for iterating. The bench writes the kernel into the DDR
model before reset, and the ROM receives a real boot image whose single
segment is only the kernel's first 4 KiB. The receive, the CRC checks,
the device-tree fixups and the entry are the same, and everything after
the ROM is identical. Only the ~420M cycles of serial transfer are
skipped.

## Requirements

On Ubuntu 24.04, beyond what the earlier steps need (Verilator 5,
`gcc-riscv64-unknown-elf`, `device-tree-compiler`):

```
sudo apt-get install -y gcc-riscv64-linux-gnu flex bison bc rsync
```

## What's verified here

- `make linux` and `make linux-fast`: both pass, with 17 checks each.
- **Builds:** from a clean `build/linux/`, and incrementally. The kernel
  and busybox `.config`s are identical to the hand-built ones that first
  booted, apart from the initramfs path.
- **Fetch:** busybox and musl were cloned fresh by `rvlinux fetch` and
  their hashes checked. The Linux tree is the one fetched earlier,
  checked against the same hash.
- **`make boot`** still passes on all three memory systems with the
  bench changes.

## Honest status

- **Simulation only.** The board build has 128 KiB of block RAM, and
  Linux needs megabytes. The board needs the AXI4 path of Step 51
  wired to the Zynq's DDR through `S_AXI_HP`. At 115200 baud the 2.6 MB
  image would also take about 4 minutes to send.
- **A tiny kernel.** No modules, block devices, networking or
  filesystems beyond procfs, sysfs, devtmpfs, tmpfs and the initramfs.
  `CONFIG_KALLSYMS` is off, so a backtrace prints addresses, not names.
- **One hart.** `SMP` is off. The SBI has no IPI, RFENCE or HSM
  extensions, and with one hart Linux never asks for them.
- **GitHub mirrors by default.** That is what this environment can
  reach. The pinned hashes are the trust anchor, not the host.
- **Wall time.** About 15 minutes for `make linux`, two-thirds of it
  pushing 2.6 MB through a simulated UART. That's why `make linux-fast` exists.

## Takeaway

None of the earlier steps was written against Linux. Each one followed
what the RISC-V specs and the device-tree bindings say a kernel can
assume. An unmodified mainline kernel booting to a shell on the first
attempt, apart from configuration, is the check that they did.

## Files

| file | |
|---|---|
| `tools/rvlinux` | fetch / build / run / check |
| `sw/linux/kernel.config`, `sw/linux/busybox.config` | the config fragments |
| `sw/linux/init`, `sw/linux/matest.c` | the initramfs's `/init`, and the misaligned-access test |
| `tb/boot_tb.v` | `+PROMPT`, `+TYPEGAP`, `+PRELOAD`; a flushed console log; prompt cycles in the summary |
| `Makefile` | `make linux`, `make linux-fast` |
