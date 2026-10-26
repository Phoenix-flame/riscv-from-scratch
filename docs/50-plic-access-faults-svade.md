# Step 50 — Underneath a kernel: PLIC, access faults, A/D bits

Step 49 gave a payload the RISC-V boot interfaces: the boot protocol, a
device tree and an SBI. Three parts of the machine underneath were still
missing, and each is something a kernel takes for granted.

- **External interrupts.** The UART raised an interrupt line that went
  nowhere, so a kernel could only poll its console.
- **Bus errors.** A load from an address with nothing behind it returned
  0, and a store to the boot ROM was silently dropped. A kernel probing a
  device that is not there, or chasing a wild pointer, has no way to
  find out.
- **Page-table A/D bits.** The walker ignored the accessed and dirty bits.
  The privileged spec allows two behaviours, and Linux needs one of them:
  either the hardware sets the bits (Svadu), or it faults so that software
  can set them (Svade).

This step adds all three to `soc_boot` and to the core under it. The PLIC
has the standard layout and an S-mode context, so the UART's interrupt
reaches a supervisor kernel as SEIP. A PMA check against the platform's
memory map turns every access to a hole, or a write to read-only memory,
into a precise access fault. The walker can now fault on clear A/D bits
(Svade), behind a parameter. A new payload, `kdemo`, handles each of them
the way Linux's trap code does, and runs as part of `make boot`.

```
make plic-sifive   # the PLIC register by register
make boot          # now four programs, including kdemo
```

## The PLIC, as the binding lays it out

Step 33's `plic.v` multiplexed sources into one line, the hart's MEIP,
through a compact 16 KiB register map of its own design. A kernel's PLIC
driver expects the layout of the `sifive,plic-1.0.0` / `riscv,plic0`
binding. It also expects a **context** of its own: a (hart, privilege)
target with its own enable bits, threshold and claim register.
`rtl/plic_sifive.v` has two contexts: 0 is hart 0 in M-mode (MEIP), and 1
is hart 0 in S-mode (SEIP), as on QEMU `virt`.

| Offset | Register |
|---|---|
| `0x000000 + 4*i` | priority of source *i* (1..31; 0 = never) |
| `0x001000` | pending bits |
| `0x002000 + 0x80*c` | enable bits of context *c* |
| `0x200000 + 0x1000*c` | priority threshold of context *c* |
| `0x200004 + 0x1000*c` | claim (read) / complete (write) of context *c* |

The gateway is Step 33's, shared by all contexts. An asserted source
becomes pending unless it is already pending or in service. A claim from
any context clears the pending bit and marks the source in service. The
complete ends the service, and a level source that is still asserted
becomes pending again. Each context sees the highest-priority source that
is pending, enabled for that context and above its threshold; the lowest
ID wins a tie. The claim's side effect fires only on a real D-port load,
for the same reason as in Step 33. `make plic-sifive` checks all of this
over 21 cases: per-context enables and thresholds, the re-pend of a level
source, pulses remembered as pending, and priority order and ties across
the two contexts.

The UART is source 10, as on `virt`. The DT gains the PLIC node, with
`interrupts-extended = <&cpu0_intc 11>, <&cpu0_intc 9>` naming the two
contexts, and the UART gains `interrupt-parent = <&plic>; interrupts =
<10>;`. In the core, `csr_s` gets a hardware SEIP input. The value read
from `mip.SEIP` is the software bit OR the line, while a CSR write still
reaches only the software bit, as the privileged spec says.

## Access faults, made precise by checking first

A bus error that comes back from the memory system arrives late. The load
is already in MEM, and younger instructions have executed behind it. This
pipeline commits every trap in EX (Steps 42 and 44), and reporting a
fault from MEM would make it imprecise. So the core never asks the bus.
It knows the memory map and checks every access against it **before**
making the access, in the stage that can still trap precisely.

`cpu_pipe_u` takes the map as parameters: `PMA_N` regions, each a base,
a size and the accesses it allows, `{X, W, R}` (physical memory
attributes, in the spec's terms). `soc_boot` passes its own map:

| Region | Base | Size | Allows |
|---|---|---|---|
| boot ROM | `0x0000_1000` | 16 KiB | R X |
| test device | `0x0010_0000` | 4 KiB | R W |
| CLINT | `0x0200_0000` | 64 KiB | R W |
| PLIC | `0x0c00_0000` | 64 MiB | R W |
| UART | `0x1000_0000` | 256 B | R W |
| RAM | `0x8000_0000` | RAM size | R W X |

There are three checkers, one for each kind of access:

- **Fetch, in IF.** The physical PC must be X. A failing fetch makes no
  request; it rides down the pipe as a fault token, the same mechanism
  Step 41 built for fetch page faults, and traps in EX with cause 1.
- **Load, store, AMO, in EX.** The check uses the translated address. A
  load needs R; a store, SC or AMO needs W. The trap is cause 5
  (load) or 7 (store/AMO), with the faulting *virtual* address in `mtval`.
  It is checked after the TLB, so a page fault takes priority, as the
  spec orders them.
- **Page-table read, in the walker.** If a PTE's address is not readable,
  the walk ends without touching the port and records an access fault.
  The access that needed the walk then traps with 1, 5 or 7, not 12,
  13 or 15.

`PMA_N = 0`, the default, allows everything, so the other SoCs behave
exactly as before.

One consequence showed up in the boot ROM. Step 49 sized RAM by aliasing:
the decoder ignores address bits above the RAM, so `RAM_BASE + size` is
the first address that reads back `RAM_BASE`'s own word. With the PMA
region sized to the real RAM, that load faults. So the probe now does
what firmware on real hardware does: it loads at `RAM_BASE + 4 KiB`,
`+ 8 KiB`, … with a temporary trap vector, and the first access fault
marks the end of RAM (`probe_ram` in `rom_start.S`). The ROM now also
delegates the three access-fault causes to S, next to the page faults.

## A/D bits: Svade, in two lines of the walker

With Svade, a leaf PTE whose A bit is clear is a page fault for any
access. A store to a page whose D bit is clear is a store page fault. The
kernel's handler sets the bit, flushes the TLB entry and returns, and the
instruction runs again. `ptw.v` (parameter `SVADE`) implements both rules
where it fills the TLB:

```
pte_bad   = ... | (SVADE & pte_leaf & ~pte_a);          // A = 0: no translation
leaf_perm = {U, X, W & (pte_d | ~SVADE), R};            // D = 0: no W in the TLB yet
```

The first rule makes the walk fail, which becomes a page fault of the
right kind (12, 13 or 15). The second caches a clean page as read-only,
so loads hit and the first store takes cause 15. When the kernel sets D
and runs `sfence.vma`, the next walk refills the entry with W.

`SVADE` defaults to 0. Every MMU program in `sw/` was written for the
earlier walkers and builds its PTEs with A and D clear (`0x17`, say).
They still run unchanged on every core; `soc_boot` sets it to 1.

## kdemo: the three, as a kernel sees them

`sw/boot/kdemo.c` is an S-mode payload. It finds the RAM, the PLIC and the
UART in the device tree and does three things:

```
[access faults]
  load from a hole                   scause  5 stval 0x40000000  ok
  ... and the load wrote nothing     ok
  store to the boot ROM (R-X)        scause  7 stval 0x00001000  ok
  AMO to a hole                      scause  7 stval 0x40000008  ok
  jump into a hole                   scause  1 stval 0x40000100  ok
  load from the ROM: no trap         ok

[A/D bits: Svade]
  read  (A clear): 1 load page fault, A set,  read 0xa5a5a5a5  ok
  write (D clear): 1 store page fault, D set  ok
  write again:     0 faults  ok
  PTE now 0x...: V R W A D, as the handler left it  ok

[external interrupts: PLIC]
  interrupt-controller@c000000: 31 sources; S-mode is context 1; serial@10000000 is source 10
type>
  got "hello, PLIC!": 12 bytes in 3 external interrupts  ok    (ideal memory)
```

**Access faults.** The handler skips the faulting load or store
(`sepc += 4`), and resumes the fetch fault at a saved address. "The load
wrote nothing" checks that the faulting load's destination register kept
its old value.

**A/D bits.** `kdemo` turns on Sv32. The kernel's RAM and the devices are
identity-mapped with 4 MiB superpages that have A and D set, and one 4 KiB
test page at `0xC000_0000` has both clear. The handler does what Linux
does for a page fault on a clear A or D bit: it sets the bit, runs
`sfence.vma` on that address, and returns without advancing `sepc`, so
the instruction runs again.

**External interrupts.** `kdemo` chooses its PLIC context the way Linux's
driver does: it is the entry in the PLIC's `interrupts-extended` that
names local interrupt 9. It enables source 10 there, sets the UART's
trigger level to 4 bytes, and prints `type> `. The testbench types a
line. Each supervisor external interrupt claims, drains whatever the UART
FIFO holds, and completes. The 12 characters plus the carriage return
arrive in three interrupts, not thirteen. The trigger level (or, for a
short tail, the receive timeout) lets several bytes collect per
interrupt.

The test is meant to fail without the hardware. With `SVADE=0`, all
three A/D checks fail (0 faults, PTE unchanged).

## What `make boot` shows now

The sequence is now seven chunks: two bad images, `dtdemo` (reboot),
`kdemo` (reboot) with the typed line, `mhello` (reboot), and
`libc_demo` (power off).

```
[rvboot] halted, exit code 0, 6988642 cycles, 3 resets, 7 chunks sent (images and typed input)
[rvboot] 27739 bytes in, 8916 bytes out; RX FIFO peak 4 of 16
[rvboot] UART transcript matches tb/boot_expected.txt (230 lines)
BOOT: ALL PASS
```

The FIFO peak is now 4, not 1, because `kdemo` lets four bytes collect
before taking an interrupt. `dtdemo`'s dump of the tree now shows the
PLIC node and the UART's `interrupts`, and the phandle numbers move up by
one.

## What's verified here

- `make plic-sifive`: 21 register-level checks of the PLIC (priorities,
  per-context enables and thresholds, claim/complete, re-pend of a level
  source, pulses, priority order and ties across both contexts).
- `make boot` with `kdemo`: precise access faults on load, store and AMO
  (with cause and `stval`); fetch from a hole; the destination register
  untouched by a faulting load; no fault on legal ROM reads; Svade load
  and store page faults, fixed up and retried; a line received by PLIC
  interrupts in S-mode; RAM size from the faulting probe (the DT still
  reports 256 KiB). The negative control: with `SVADE=0`, the A/D checks
  fail.
- Regressions for the shared files (`cpu_pipe_u`, `csr_s`, `ptw`), with
  the new parameters at their defaults: `pipe-u` (riscv-tests 90/90 in M
  and with Sv32 on in U), `pipe-u-sv`, `bench-counters`, `smode` (the
  other `csr_s` user), `tlb`, `vec` (all seed sets, with and without
  caches), `cache`, and all nine `rvgen-all` presets.

## Cost

Yosys 0.33, `synth_xilinx -flatten -abc9 -arch xc7`:

| | LUTs | FFs | CARRY4 |
|---|---:|---:|---:|
| `plic_sifive` (31 sources, 2 contexts, 3-bit priorities) | 1,070 | 226 | 12 |
| `cpu_pipe_u` as `soc_boot` builds it, Step 49 (no PMA, `SVADE=0`) | 10,319 | 5,753 | 1,085 |
| `cpu_pipe_u` as `soc_boot` builds it, Step 50 (6 PMA regions, `SVADE=1`) | 10,725 | 5,756 | 1,136 |

The core configuration is RV32IMA, M/S/U, the MMU, Zb*, the branch
predictor and the counters, with no vectors. The core's +406 LUTs are
mostly the PMA checkers: three of them (fetch, data, walker), each
comparing an address against six base/size pairs, which accounts for
the 51 extra CARRY4s. Power-of-two regions, compared by mask, would make
these comparisons almost free, but the ROM's 16 KiB at `0x1000` is not
aligned to its size. The 3 flip-flops are the access-fault tags in IF/ID
and ID/EX and the walker's `wres_af`. The PLIC is mostly the two 31-way
priority arbitrations and the read multiplexer over 31 priority
registers; a kernel needs only a handful of sources, and `SOURCES = 15`
would roughly halve it.

## Honest status

- Verified in simulation only, on ideal memories (Step 49's caveat
  stands).
- The PMA check covers scalar loads, stores, AMOs, fetches and page-table
  reads. It does **not** cover the vector unit's element accesses, which
  `soc_boot` does not build (`V_EXT = 0`). Misaligned accesses still
  neither trap nor work.
- A PTE read that is not allowed reports an access fault, but the walker
  does not check the other reserved encodings the spec lists: A/D/U set
  in a non-leaf PTE, or a misaligned superpage (a level-1 leaf whose
  PPN[0] is not 0).
- The CLINT's `msip` still does not reach the core (one hart; no IPIs).
- Linux needs megabytes of RAM; `soc_boot` has 256 KiB of ideal memory
  that is not block RAM. That is the next step.

## Takeaway

None of these three adds a feature a program asks for. Each tells the
kernel something it would otherwise not know: which device needs it,
that an address has nothing behind it, which pages it has used and
written. The access faults in particular are cheap only because they are
checked against a map before the access, not reported by the bus after
it.

## Files

| file | |
|---|---|
| `rtl/plic_sifive.v`, `tb/plic_sifive_tb.v` | the standard-layout PLIC and its test (`make plic-sifive`) |
| `rtl/cpu_pipe_u.v` | `meip` / `seip` inputs; the PMA checker (`PMA_*`) on fetch, data and walker accesses; causes 1 / 5 / 7; `SVADE` |
| `rtl/ptw.v` | `SVADE`; `mem_ok` / `done_af` for unreadable PTEs |
| `rtl/csr_s.v`, `rtl/cpu_mc_s.v` | hardware SEIP |
| `rtl/soc_boot.v` | the PLIC, the PMA map, `SVADE = 1` |
| `rtl/soc_pipe_u.v`, `rtl/soc_pipe_c.v`, `rtl/oz/oz_rv_soc.v`, `tb/rvtest_p[uc]_tb.v` | tie `meip` / `seip` to 0 |
| `sw/boot/kdemo.c` | the S-mode payload above |
| `sw/boot/rom_start.S`, `rom_main.c` | RAM probing by access fault; access faults delegated to S |
| `sw/boot/rvfs-soc.dts`, `platform.h` | the PLIC node, the UART's interrupt |
| `sw/boot/ns16550.[ch]` | `ns16550_rx_irq()` |
| `tb/boot_tb.v`, `tools/rvboot`, `tb/boot_expected.txt` | the `type> ` prompt, kdemo and its input in the sequence |
