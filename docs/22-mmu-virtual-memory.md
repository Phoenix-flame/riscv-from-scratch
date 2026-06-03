# Step 22 — Virtual memory: an Sv32 MMU

Step 21 gave us privilege levels: user code can't execute privileged
instructions. But it could still read or write *any memory address* —
including another program's data or the UART. Real isolation needs an **MMU**:
hardware that translates the addresses a program uses (**virtual** addresses)
into real (**physical**) addresses through page tables the kernel controls. A
program can only touch memory the kernel has mapped for it; everything else
faults.

This step implements RISC-V **Sv32** — the 32-bit two-level paging scheme — for
data accesses, with a hardware page-table walker and page-fault exceptions.

## Sv32 in one picture

A 32-bit virtual address splits into two 10-bit page-table indices and a 12-bit
offset; a 4 KiB page is the unit of mapping:

```
VA = | VPN[1] (10 bits) | VPN[0] (10 bits) | page offset (12 bits) |

satp (CSR 0x180) = | MODE (1) | ASID (9) | PPN (22) |     MODE=1 => Sv32 on
                                            └─ physical page of the root table
```

Translation is a two-level walk:

```
pte1 = mem[ satp.PPN*4096 + VPN[1]*4 ]
   if pte1 is a leaf (R or X set)  -> 4 MiB "superpage";  PA = pte1.PPN1 : VA[21:0]
   else                            -> pte0 = mem[ pte1.PPN*4096 + VPN[0]*4 ]
                                      PA = pte0.PPN : VA[11:0]   (4 KiB page)
```

Each PTE carries permission bits: `V` valid, `R`/`W`/`X` read/write/execute, and
`U` — whether *user* mode may use the page. If a walk hits an invalid PTE, or the
permissions don't allow the access, the hardware raises a **page-fault**
exception (cause 13 load, 15 store), and the kernel decides what to do.

## When translation is on

In this core (machine + user modes only), translation is active **in user mode
when `satp.MODE = Sv32`**. Machine mode always uses physical addresses — which is
exactly what the kernel needs to build page tables and to run its trap handler.
So the model is: the M-mode kernel runs on physical memory, sets up a page table
and `satp`, and `mret`s into U-mode, where every data address the user touches is
now translated.

(Scope: this MMU translates **data** accesses. Instruction fetch stays physical
here — see the note at the end. Translating fetch is the same walk on the PC.)

## The hardware

`rtl/mmu.v` is a combinational Sv32 walker. Given the virtual address, `satp`,
and the current privilege, it reads the one or two PTEs it needs and outputs the
physical address plus a fault signal:

```verilog
assign active = (priv == 2'b00) && satp[31];          // U-mode + Sv32
assign walk_addr1 = {satp[21:0],12'b0} + {vpn1,2'b0};  // level-1 PTE address
//   ... read pte1; if leaf -> superpage, else read pte0 at level 0 ...
assign fault = active & req & (walk_fault | perm_fault);
assign pa    = active ? translated : va;               // identity when off
```

Because our RAM model reads combinationally, the walker fetches both PTEs and the
core completes the access in a single cycle. That's idealized — **real MMUs walk
over several cycles and cache translations in a TLB** so they don't re-walk on
every access. The logic, though, is exactly the real thing.

Two pieces of plumbing make it work:

- **`satp` CSR** (`csr.v`): the kernel writes it to point at the root page table
  and switch translation on.
- **Page-walk read ports on the RAM** (`dmem.v`): two extra combinational read
  ports the walker uses to fetch PTEs, wired up in `soc_mmu.v`. (A real system
  walks through the normal memory port; the dedicated ports are a simulation
  convenience.)

The core (`cpu_core_mmu.v`) feeds the data address through the MMU, drives the
*physical* address onto the bus, and turns a walker fault into a trap using the
same machinery as every other exception.

## The demo: a remap you can see, and a fault you can catch

`sw/mmu_demo.c` (kernel, machine mode) builds a tiny page table:

```c
pt[0] = (0x00 << 20) | V|R|W|X|U;   // VA [0,4MiB)        -> PA [0,4MiB)  identity
pt[2] = (0x40 << 20) | V|R|W|U;     // VA [8MiB,12MiB)    -> PA 0x10000000 (UART!)
//        everything else stays invalid (V=0)
csrw satp, 0x80000000 | (PT_BASE >> 12);     // Sv32 on
// ... set MPP=U, mepc=user_main, mret -> drop into user mode
```

The second entry is the interesting one: it maps virtual `0x00800000` onto the
UART's physical address `0x10000000`. So when the user writes to `0x00800000`,
the text comes out the UART — through an address that is *not* the UART's
physical address. Then the user touches an unmapped address:

```bash
make mmu
```

```
kernel: page table built, Sv32 on, dropping to user mode
kernel: mapped VA 0x00800000 -> PA 0x10000000 (UART)
user: this text reaches the UART via VIRTUAL addr 0x00800000
user: (its physical addr 0x10000000 is not even mapped for me)
user: a mapped RAM page reads back correctly
user: now touching UNMAPPED 0x40000000 ...
kernel: PAGE FAULT from user (caught by handler) -> halting
```

Three things are demonstrated, all by hardware:

1. **Real translation.** User text reaches the UART via `0x00800000`; the page
   table walk remapped it to physical `0x10000000`. Virtual ≠ physical.
2. **Confinement.** The user can only reach what the kernel mapped. Its own data
   and the (remapped) UART work; the line after the unmapped access never runs.
3. **Page faults.** Touching `0x40000000` (no valid PTE) raised a store
   page-fault that the kernel caught — the foundation for demand paging, copy-on-
   write, swapping, and per-process isolation.

## What this unlocks, and what's simplified

With page tables, each process can have its *own* address space — the same
virtual addresses mapping to different physical pages — which is how an OS keeps
processes from seeing each other. Page faults are the hook for demand paging
(map a page lazily on first touch) and copy-on-write (share until written).

Simplifications worth knowing:

- **Data only.** Instruction fetch stays physical here. Translating fetch is the
  identical walk applied to the PC, raising cause 12 (instruction page fault) —
  a natural extension given our split instruction/data memories.
- **No TLB.** The walk is combinational; real cores cache translations.
- **No A/D bits, no `sfence.vma`.** We don't set accessed/dirty bits or model
  TLB-invalidation fences, since there's no TLB to invalidate.
- **Superpages and 4 KiB pages** are both supported by the walker; the demo uses
  4 MiB superpages for a compact page table.

## Takeaway

An MMU is just "look the address up in a table before using it," made into
hardware. From that one idea — translate every access through kernel-controlled
page tables, and fault when there's no valid mapping — comes the entire modern
memory model: process isolation, virtual address spaces, demand paging, and
memory protection that the application cannot escape, because it never sees a
physical address at all.
