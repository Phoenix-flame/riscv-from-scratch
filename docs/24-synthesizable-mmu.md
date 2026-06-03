# Step 24 — A synthesizable MMU: the multi-cycle page-table walker

Step 22 built an Sv32 MMU, but its walker was **combinational** — it chained two
same-cycle memory reads through dedicated walk ports. That can't run on real
hardware, because block RAM reads are **registered** (data a cycle late). Step 23
made the core synthesizable but left the MMU out. This step puts virtual memory
on the synthesizable core, with **page tables living in block RAM** and the
translated physical address free to target RAM *or* a peripheral. No DDR needed.

## The idea: walk the page table over several cycles

The combinational walk becomes a small extension of the multi-cycle FSM. A data
load/store in user mode with Sv32 enabled now takes this path instead of going
straight to the access:

```
EXEC  -> PTW1  : drive the level-1 PTE address      (satp.ppn*4096 + VPN1*4)
         PTW1D : level-1 PTE is valid (registered read)
                   leaf?    -> superpage: form PA, go to ACC
                   pointer? -> drive level-0 PTE address, go to PTW0D
                   bad?     -> go to PF (page fault)
         PTW0D : level-0 PTE is valid
                   leaf + perms ok -> form 4 KiB PA, go to ACC
                   else            -> PF
         ACC   : drive the translated physical address (store writes here)
         ACCD  : (loads) capture data
         PF    : raise a page-fault trap (mcause 13 load / 15 store)
```

The crucial difference from the sim MMU: the walk reuses **the one data port**,
reading each PTE on a normal registered bus cycle. That's exactly how real CPUs
do it — no magic extra read ports. Translation is gated by
`cur_priv == U && satp.MODE == 1`; in machine mode (or with Sv32 off) the FSM
skips the walk and uses the address directly, so the kernel can build the page
table in RAM untranslated.

## The bug worth remembering: a combinational loop through a peripheral

The first version hung. The cause is a good lesson in why registered reads
matter. In `PTW1D` the next address (`pte0_addr`) is computed from the PTE that
was just read. If the level-1 PTE is a **leaf** (a superpage), `pte0_addr` is
meaningless — and for the demo's UART mapping it happened to compute to
`0x10000000`, the UART. The UART's read is *combinational*, so:

```
dmem_addr -> (selects UART) -> drdata -> pte -> pte0_addr -> dmem_addr
```

closes a zero-delay feedback loop with no register to break it — the simulator
spins forever, and real hardware would have an asynchronous loop. RAM reads don't
have this problem because the block RAM's output register breaks the path. The
fix: the walker only ever drives a level-0 address when it's genuinely descending
through a non-leaf pointer (which, by construction, points at the next page table
in RAM). Page tables must live in RAM — a completely standard requirement.

## Showing it works

`make mmu-hw` builds a demo (`sw/mmu_hw_demo.c` + `sw/mmu_htrap.S`) that, in
machine mode, builds a page table **in BRAM**:

- `pt[0]`: identity-map the low 4 MiB (so code and stack work), and
- `pt[2]`: map virtual `0x0080_0000` to physical `0x1000_0000` — the UART.

It sets `satp`, drops to user mode (`mret`), and the user program prints through
the **virtual** UART address `0x0080_0000`, then writes an **unmapped** address:

```
user:VM ok        <- printed via VA 0x00800000, translated to the UART PA
PF                <- store to unmapped 0x40000000 -> page fault -> M-mode handler
[soc] halted (LED on)
```

The user never names the UART's real address; the MMU remaps it. A separate test
(`sw/mmu_hw_4k.c`) maps the same VA through a level-1 **pointer** plus a level-0
leaf, exercising the two-level 4 KiB descend path (`PTW0D`) and printing
`4K ok`.

## Files

- `rtl/cpu_mc_mmu.v` — the multi-cycle core with the integrated Sv32 walker.
- `rtl/soc_fpga_mmu.v` — the SoC (same as `soc_fpga`, more RAM for the page
  table, wired to `cpu_mc_mmu`).
- `sw/mmu_hw_demo.c`, `sw/mmu_htrap.S`, `sw/mmu_hw_4k.c` — demos.
- `tb/mmu_hw_tb.v` — captures the UART bytes and stops on halt.

Everything is synthesizable (registered-read BRAM, real UART, halt register).
As with Step 23, functional correctness is verified in simulation here; bitstream
generation needs Vivado.

## What this unlocks (and what's still ahead)

Data-side virtual memory now runs in fabric. Natural next steps, in rough order:

- **Translate instruction fetch too** (currently only data is translated, so user
  code runs at its physical PC). That's a second walker on the fetch port, or a
  shared walker with arbitration.
- **A TLB** to cache translations, so most accesses skip the multi-cycle walk —
  important once both fetch and data are translated, or the core gets slow.
- **Two user processes + timer preemption** to show real per-process address
  spaces (each with its own `satp`).
- **Supervisor mode and `medeleg`/`mideleg`** so faults go to S-mode — the real
  OS layering, and the point where this starts to resemble a chip that could boot
  a small kernel.

## Takeaway

Virtual memory on hardware is, at its heart, the combinational page-table walk
turned into a little state machine that reads PTEs over the normal memory bus.
The registered-read discipline that forced the multi-cycle core in Step 23 is the
same discipline that makes the walker correct here — and the one place it was
violated (a peripheral in the walk path) is exactly where it broke.
