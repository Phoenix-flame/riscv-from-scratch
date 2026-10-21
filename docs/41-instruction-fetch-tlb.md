# Step 41 — Translated instruction fetch and a TLB

The synthesizable MMU of Step 24 left two things out, and Step 38 had to work
around both. First, only *data* addresses were translated: the PC was always a
physical address, so a user program's code could not be placed, protected or
isolated by the page table. Second, there was no cache of translations. Every
user load and store walked the page table, two extra RAM reads before the access
itself, and there was nothing to invalidate when `satp` changed, which is why
Step 38's context switch needed no `sfence.vma`.

This step closes both gaps on a new core, `rtl/cpu_mc_tlb.v`, which is
`cpu_mc_mmu` plus:

- **translated fetch.** In U-mode with Sv32 on, the PC is a virtual address and
  the instruction ROM is indexed by its physical translation. A leaf without `X`
  (or without `U`) raises an **instruction page fault**, `mcause` 12, with `mepc`
  set to the faulting PC.
- **an I-TLB and a D-TLB** (`rtl/tlb.v`, 4 entries each by default). A hit
  costs no cycles at all; only a miss runs the walker.
- **`sfence.vma`**, which flushes them: every entry for `sfence.vma x0`, or just
  the ones mapping `rs1`. It is machine-mode only, and illegal from U.

`cpu_mc_mmu` itself is unchanged, so Steps 24 and 38 still run on it exactly as
before.

## The TLB

`tlb.v` is a small fully-associative table. Each entry is one cached leaf PTE:

```
valid | super | VPN tag (20) | PPN (22) | U X W R
```

A lookup is combinational: the VA's VPN is compared against every valid tag at
once. A 4 KiB entry must match all 20 VPN bits. A 4 MiB superpage entry matches
only `VPN[1]` and passes `VA[21:0]` straight through. The output is `hit`, the
physical address, and the four permission bits. The TLB does not decide whether
the access is allowed. Only the core knows what the access needs (`X` for a
fetch, `R` for a load, `W` for a store), so it checks the bits itself.

A fill happens whenever the walker reaches a valid leaf, and it overwrites a
round-robin victim. The leaf is cached even when this access then fails on
permissions. The PTE itself is good, and the next access to that page may need
different permissions. Because entries are filled only on a miss, two entries
can never match the same VA.

There are two instances because there are two lookups per instruction at
different times: the I-TLB is looked up with the PC during `FETCH`, the D-TLB with
the effective address during `EXEC`. A shared TLB would work, but the two streams
would keep evicting each other's entries.

## The FSM

```
FETCH --M-mode, or I-TLB hit + X ok-------------------> EXEC
FETCH --I-TLB miss--> PTW1 -> PTW1D [-> PTW0D] -> IRD -> EXEC
EXEC  --M-mode, or D-TLB hit + R/W ok------> ACC [-> ACCD] -> FETCH
EXEC  --D-TLB miss--> PTW1 -> PTW1D [-> PTW0D] -> ACC [-> ACCD]
any bad PTE, or a leaf without the needed permission  -> PF (12 / 13 / 15)
```

Both walks use the **same walker states and the same single data port**. A
one-bit register, `iwalk`, records whose walk it is. It selects the VA being
walked (`pc` or the ALU's effective address), the permission rule, the fault
cause, and which TLB receives the fill. A fetch walk is safe on the data port
because it happens before the instruction executes, when the port is idle.

The one subtle part is the instruction address. The ROM is a registered block
RAM that re-reads `imem_addr` **every** cycle, and a multi-cycle instruction
needs its word to stay on `imem_rdata` until it retires. On `cpu_mc_mmu` that
was free, because `imem_addr` was just `pc`. Here the physical fetch address is
latched into `ipa`:

```verilog
wire [31:0] fetch_pa = xlate_active ? itlb_pa : pc;
assign imem_addr = (state == S_FETCH) ? fetch_pa : ipa;
```

`FETCH` presents the translated PC and latches it. Every later cycle of the same
instruction, including any D-side walk it triggers, keeps presenting `ipa`. After
a fetch walk the walker writes `ipa` itself and spends one cycle in `IRD` so the
ROM can read it. Going back through `FETCH` would also work with a TLB, but on
the `TLB_EN=0` build used for measurement it would miss again forever.

## The demo

`make tlb` builds `sw/tlb_demo.c` (kernel) and `sw/tlb_asm.S` (trap handler and
user program). A separate link script, `sw/link_tlb.ld`, places the user code
in its own section, `.utext`, at **physical** ROM address `0x1000`. The kernel
maps it at **virtual** `0x00403000`, execute-only:

| VA | PA | perms | purpose |
|---|---|---|---|
| `0x00403000` | `0x1000` (ROM) | `X U` | user code |
| `0x00404000` | `0x4000`, later `0x5000` | `R W U` | user data |
| `0x00406000` | `0x4000` | `R W U` | same data page, not executable |
| `0x10000000` (4 MiB) | `0x10000000` | `R W U` | UART |

The test is built so that untranslated fetch fails loudly. The ROM has 4096
words, so an untranslated PC of `0x00403xxx` would index ROM word `0x3xxx`,
which is zero, and the program would die at its first instruction. The user
program then runs four phases:

1. **A hot loop** of 100 stores and loads. After the first touch of each page,
   every fetch and every access hits.
2. **Execute-only.** It reads its own code page. `X` without `R` makes that a
   load page fault (13); the kernel counts it and skips the load.
3. **A stale translation.** It stores `0x11111111`, then `ecall`s the kernel,
   which repoints the data PTE at PA `0x5000` *without* `sfence.vma`. The next
   store, `0x22222222`, still hits the old D-TLB entry and lands in **PA
   `0x4000`**. A second `ecall` runs `sfence.vma a0` for just that VA. The
   third store, `0x33333333`, re-walks and lands in PA `0x5000`.
4. **An instruction page fault.** It jumps to `0x00406000`, which is mapped but
   not executable. That raises `mcause` 12 with `mepc = 0x00406000`, and the
   kernel prints `IPF` and halts.

`tb/tlb_tb.v` runs the image on two SoCs side by side, one with 4-entry TLBs and
one built with `TLB_EN=0`, where nothing is cached and every fetch and every
access walks:

```
---- Step 41: translated fetch + I/D TLBs ----
TLB
IPF

                     fetches  I-miss   data  D-miss   cycles
  4-entry TLBs          588       2    225       4     2050
  no TLB (walk)         561     561    216     216     4840
  user fetches at VA 0x00403xxx served from PA 0x00001xxx: 586
  stale store (PTE changed, no sfence yet): TLB -> PA 0x4000 = 22222222, walk -> PA 0x5000
  speedup 2.36x
TLB: ALL PASS (fetch translation + I/D TLBs + sfence.vma + fetch faults)
```

On both SoCs it checks the closing fault (`mcause` 12, `mepc`), the single
load fault, the checksum, and the two `ecall`s. Phase 3 is checked
*differently* on each. With a TLB, PA `0x4000` must hold the stale store
`0x22222222`. Without one, the PTE change takes effect immediately and PA `0x4000`
keeps `0x11111111`. So the testbench shows that the TLB really caches, and
also why `sfence.vma` exists.

The two I-TLB misses are the code page and the final, faulting jump. The selective
`sfence.vma` dropped only the data page, so the code page entry survived. The
four D-TLB misses are the data page, the UART superpage, the read of the code
page, and the data page again after the fence. The fetch counts differ slightly
between the two runs only because the user program polls the UART's ready bit,
and the slower core spends fewer iterations waiting.

## riscv-tests with translation on

The demo shows the TLB working. The official suite shows that nothing else
broke. `tools/rvtests` gains an `mc_tlb` core that builds the suite with
`-DRVTEST_VM`. Under that flag the target environment
(`tests/riscv-tests/env/riscv_test.h`) builds an identity map before entering the
test: one 4 MiB superpage, VA `0` → PA `0`, `V R W X U`, in a zeroed page in
`.bss`. It also leaves `mstatus.MPP` at U, so the `mret` into the test body
lands in user mode. **Every instruction of rv32ui and rv32um is then fetched
through the I-TLB, and every load and store goes through the D-TLB.** Results
are still reported through the M-mode trap vector, untranslated.

```
make riscv-tests CORE=mc_tlb
  rv32ui 40/40   rv32um 8/8      total 48/48   ALL PASS
```

`fence_i` and `ma_data` remain the known gaps, for the same reasons as on `mc`.
Rebuilding with `TLB_EN=0` also passes 48/48 at about 2.3× the cycles
(`rv32ui-add`: 991 → 2275), which confirms the tests really ran translated.
Without `-DRVTEST_VM` the environment is unchanged, so every other core runs
exactly as in Step 40.

## Honest status

- Verified in simulation only.
- **No ASIDs.** Entries are not tagged with `satp.ASID`, so software must
  `sfence.vma` after every `satp` change, as if ASIDLEN were 0 (the `satp`
  ASID field is still writable, from the shared `csr.v`). Tagging entries with the ASID, and honouring the `G`
  bit, would let a context switch keep the other process's translations.
- **`sfence.vma rs1, rs2`** flushes by address when `rs1 ≠ x0` and flushes
  everything otherwise. `rs2` (the ASID) is ignored, which over-flushes, as the
  spec permits.
- The walker still ignores the `A`/`D` bits and does not check that a
  superpage's `PPN[0]` is zero, just like `cpu_mc_mmu`.
- There is no `mtval`. The faulting address of an instruction page fault is in
  `mepc`, but a data fault's address is not recorded.
- Translation is still U-mode only. There is no S-mode on this core (that is
  `cpu_mc_s`, Step 39) and no `MPRV`.
- The fetch side is still Harvard. A translated PC indexes the instruction ROM
  and a translated data address indexes the data RAM, so the same PA means two
  different memories depending on which side translated it.
- Step 38's two-task scheduler still runs on `cpu_mc_mmu`. Porting it here would
  need its page tables to map the task code with `X` and its context switch to
  `sfence.vma`. That is a small kernel change, and the natural next step.

## Takeaway

Translating fetch reuses the walker that data accesses already had. The hard
part was keeping the instruction word stable while the PC is no longer the
address the ROM sees. The TLB is a few registers and comparators, and it removes
the walk from nearly every access. In exchange, the hardware no longer always
agrees with the page table: a PTE change is invisible until software says
`sfence.vma`. Step 38 never had that problem, because it never cached anything.
