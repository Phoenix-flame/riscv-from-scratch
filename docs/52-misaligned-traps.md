# Step 52 — Misaligned accesses trap

`cpu_pipe_u`'s data port moves one aligned word. Until now nothing
stopped a load or store that does not fit in one: a `lw` at an address
ending in `01` read the aligned word around it, and a `sw` there wrote
all four bytes of that word with the value unshifted. No trap, no error,
just the wrong bytes. The store path shows why:

```verilog
wire [1:0] ba = exmem_addr[1:0];
wire [3:0] st_mask = (exmem_funct3[1:0]==2'b00) ? (4'b0001 << ba) :
                     (exmem_funct3[1:0]==2'b01) ? (4'b0011 << ba) : 4'b1111;
```

A halfword at `ba = 3` shifts its mask off the end of the word, and a
word ignores `ba` altogether.

Compiled code rarely does this, because GCC's RISC-V tuning assumes
misaligned accesses are slow and splits them itself. A kernel does it
on purpose, though: Linux runs one misaligned load at boot to learn
whether the hardware traps, and it promises user space that misaligned
loads and stores work, emulating them when they trap. On hardware that
does them silently wrong, neither works. This step makes them trap, the
way the privileged spec says, so that software can do them correctly.

```
make boot          # kdemo's new section: trap, emulate, check
```

## The rule

| access | misaligned when | cause | `mtval` / `stval` |
|---|---|---|---|
| `lh`, `lhu` | address bit 0 set | 4, load address misaligned | the virtual address |
| `lw`, `lr.w` | address bits 1:0 not 0 | 4 | the virtual address |
| `sh` | address bit 0 set | 6, store/AMO address misaligned | the virtual address |
| `sw`, `sc.w`, `amo*.w` | address bits 1:0 not 0 | 6 | the virtual address |
| taken branch, `jal`, `jalr` | target bit 1 set (no C extension) | 0, instruction address misaligned | the target |

Bytes are never misaligned. An LR counts as a load and an SC as a store,
as the spec says. A jump that would go to a bad target traps on the jump
itself. Its `rd` is not written, and `mepc` points at the jump, not at
the target.

The spec lets an implementation report a misaligned access either before
or after translation. Here it is checked before. A misaligned access
never starts a page walk, never takes a page fault or an access fault,
and never reaches the bus. That keeps it to one comparison in EX, next
to the others.

## The change

In EX, alongside the page-fault and access-fault checks:

```verilog
wire ex_misal  = ex_mem & ((idex_funct3[1:0] == 2'b01) ? ex_va[0] :
                           (idex_funct3[1:0] == 2'b10) ? (ex_va[1:0] != 2'b00) : 1'b0);
wire ex_imisal = idex_valid & ex_taken & ex_target[1];   // no C: IALIGN = 32
```

`ex_mem` covers loads, stores, LR, SC and the AMOs, which all have
`funct3 = 010`. Vector memory instructions don't set it; they have their
own path through the vector unit. Both signals join `exception`, so they
commit precisely, as every other trap does in this core: an instruction
that traps never reaches MEM. They also gate translation and the PMA
check:

```verilog
wire ex_xlate   = ex_mem & vm_on & ~ex_misal;
wire ex_daf_pma = ex_mem & ~ex_misal & ~ex_dfault & ~ex_dwalk & ...;
```

The cause goes after illegal instruction, ecall and ebreak (which can't
happen together with these) and before the page and access faults. The
tval is the virtual address, or the jump target.

The boot ROM delegates the two new causes to S-mode. It already
delegated cause 0. A kernel can then emulate a misaligned access
without a round trip through the SBI:

```c
csr_write(medeleg, ... | (1u << 4) | (1u << 6) | ...);
```

## Trap and emulate: kdemo

`kdemo` (Step 50) is the S-mode payload that shows what a kernel's trap
handler sees. It gets a fourth section. To emulate a load, the handler
must write the loaded value into the instruction's `rd`, by register
number. A compiler-generated interrupt function can't do that, so this
section uses a trap entry like a kernel's: `ma_trap` stores all 32
registers in a frame on the stack, calls `ma_handle(frame)`, reloads
them, and `sret`s. `ma_handle` does what Linux's `handle_misaligned_load`
and `handle_misaligned_store` do for RV32I:

1. Read the instruction at `sepc` and decode it.
2. Move the bytes one at a time with byte accesses, which can't be
   misaligned.
3. Sign-extend for `lh`, then write `frame[rd]`, or read `frame[rs2]` for
   a store.
4. Step `sepc` past the instruction.

An AMO, LR or SC is reported but not emulated: done in pieces it would
not be atomic, and Linux answers it with SIGBUS.

```
[misaligned: trap and emulate]
  lw  at buf+1 -> 0x14131211   scause 4 stval buf+1  ok
  lw  at buf+3 -> 0x16151413   scause 4 stval buf+3  ok
  lh  at buf+5 -> 0xffff8015   scause 4 stval buf+5  ok
  lhu at buf+5 -> 0x00008015   scause 4 stval buf+5  ok
  sw  at buf+2, bytes ok       scause 6 stval buf+2  ok
  sh  at buf+7, bytes ok       scause 6 stval buf+7  ok
  amoadd.w at buf+2            scause 6 stval buf+2  ok
  lr.w at buf+1                scause 4 stval buf+1  ok
  sc.w at buf+3, rd kept       scause 6 stval buf+3  ok
  jalr to 1f+2, rd kept        scause 0 stval = target  ok
  beq to 1f+2                  scause 0 stval = target  ok
  aligned lw/lhu, any lbu/sb   no trap  ok
```

Each line checks four things:
- exactly one trap;
- the cause;
- the `stval`;
- the value: the loaded result, the bytes around a store, memory left
  untouched by a trapped AMO, or `rd` left unwritten by a trapped SC or
  `jalr`.

The last line is the control: aligned accesses and bytes don't trap.

**Negative control.** The same `kdemo` on the Step 51 core fails all
eleven misaligned checks: no trap, so no cause and no tval, and the
loads return the wrong word. The aligned line still passes.

## Linux

The point of all this is a kernel. Linux 6.18, built for this platform
(RV32IMA, no FPU, no C; the build is not part of this repository), was
booted on `soc_boot`'s DDR configuration in simulation with this core
and this ROM, configured with `RISCV_EMULATED_UNALIGNED_ACCESS`. A static
user program then did misaligned loads and a store, and a misaligned AMO
in a child process:

```
rvfs# matest
lw @+1 = 14131211, lh @+3 = 00001413, lhu @+7 = 00001817, sw @+9 -> d4 c3 b2 a1: ok
[    3.286733] matest[23]: unhandled signal 7 code 0x1 at 0x000101e8 in matest[1e8,10000+c000]
[    3.314984] status: 00000020 badaddr: 0001d0a2 cause: 00000006
amoadd.w @+2 in a child: SIGBUS  ok
```

The loads and the store trap into the kernel, which emulates them and
returns. The AMO traps with cause 6 at the right address, and the kernel
delivers SIGBUS. Before this step the same kernel had to be built
assuming slow misaligned accesses, so that it skipped its boot-time
check, and a misaligned access in a program would have silently
returned the wrong value.

## riscv-tests

`rv32ui-ma_data` is all misaligned loads and stores, with no trap
handler, so it can't pass on a core that traps. On the `pipe_u` and
`pipe_c` cores it now stops at the first access with a trap, which is
what the `s6` core has always done, instead of reading wrong bytes. It
stays listed as a known gap (`tools/rvtests`), with the reason updated.
Everything else is unchanged: 90/90, and 91/91 on the unified-memory
variants.

## What's verified here

- `make boot`, on ideal memory, caches + block RAM, and caches + DDR:
  the twelve checks above, with the transcript now 244 lines. The
  negative control, on the Step 51 core, fails all eleven misaligned
  checks.
- `make boot-board` (the board ROM, built with the new delegation).
- riscv-tests on all six `cpu_pipe_u` builds: `pipe_u`, `pipe_u_vm`,
  `pipe_u_uni`, `pipe_c`, `pipe_c_vm`, `pipe_c_uni`.
- The core's own benches: `pipe-u`, `pipe-u-sv`, `tlb`, `cache-unit`,
  `cache`, `vec`, `bench-counters`, `bpred`, `smode`, and all of
  `rvgen-all`. None of their programs made a misaligned access, which
  is what you'd expect from compiled code, but a trap would have shown
  up as a failure.
- Linux 6.18 with the user-space test above (out of tree).

## Cost

`make boot-synth` (Yosys 0.33, `synth_xilinx -flatten -abc9 -arch xc7`)
for `fpga_top_boot`:

| | LUTs | FFs | CARRY4 |
|---|---:|---:|---:|
| Step 51 | 14,009 | 7,347 | 1,240 |
| Step 52 | (synthesis pending) | | |

The logic is two small address checks, a little extra cause and tval
selection, and two gates on translation. It adds no state.

## Honest status

- This step changes `cpu_pipe_u` only, the core under `soc_boot`, the
  OpenZynq builds and the `pipe_u`/`pipe_c` SoCs. The multi-cycle `mc`
  cores still do misaligned accesses silently wrong. `s6` already
  trapped. The byte-addressed `sc` and `pipe` cores do them correctly in
  hardware.
- The vector unit's element accesses are not checked; `soc_boot` doesn't
  build it (`V_EXT = 0`).
- Misaligned traps that reach M-mode are not emulated by the ROM's SBI.
  An S-mode payload gets them delegated, which is what Linux expects. An
  M-mode payload (`mhello`) has to handle its own, as any M-mode program
  does.
- Emulation is slow: every misaligned access is a trap, a decode and a
  handful of byte accesses. That is the bargain the spec offers: correct
  everywhere, and fast only where hardware handles it.

## Takeaway

A misaligned access that silently does the wrong thing is worse than
one that is slow, because nothing above the hardware can tell it
happened. Trapping costs two comparisons. It turns the case into
something software can see, and once software can see it, it can fix it.

## Files

| file | |
|---|---|
| `rtl/cpu_pipe_u.v` | `ex_misal` / `ex_imisal`: causes 0 / 4 / 6, the tval, checked before translation |
| `sw/boot/rom_main.c` | causes 4 and 6 delegated to S |
| `sw/boot/kdemo.c` | a kernel-style trap entry (`ma_trap`) and emulator (`ma_handle`); the new section |
| `tb/boot_expected.txt` | its fourteen new lines |
| `tools/rvtests` | `rv32ui-ma_data`'s known-gap reason |
