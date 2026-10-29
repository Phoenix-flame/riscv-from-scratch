# Step 61 — Loads and stores in the last page: one cycle in EX

> **Followed by Step 62** (`docs/62-55mhz.md`): the board at 55.56 MHz.

Step 58's `XLATE_2C` gave every load and store two cycles in EX. Cycle A
looks up the D-TLB and registers the answer; cycle B makes the decisions
that depend on it: the faults, the region check, a walk, the commit.
After Step 60 those extra cycles were most of what CoreMark still spent
outside instructions, bubbles and misses: 3.5M of 17.5M cycles.

`D_PAGE=1` (with `XLATE_2C`) does cycle A in ID for most of them.

## The result

| | Step 60 | Step 61 |
|---|---|---|
| CoreMark/MHz (`brd-c16k-l40`) | 2.289 | **2.526** (+10 %) |
| Dhrystone DMIPS/MHz | 0.934 | **1.173** (+26 %) |
| CoreMark cycles outside instructions, bubbles and misses | 3.51M | 1.87M |
| U-Boot + Linux, reset to shell (50 MHz, as Step 59) | 304.4M cycles | **284.5M** |

## How

- **The page register.** `dp_*` holds the page of the last load or store
  whose lookup finished in cycle B: its virtual and physical page numbers
  and its permissions. It is valid only if the lookup hit, or translation
  was off.
- **The address in ID.** A load or store whose base register needs no
  forwarding has its exact address in ID already: the register file's
  value plus the immediate. It needs no forwarding when neither the
  instruction in EX nor the one in MEM writes that register. Atomics are
  left out.
- **The match.** If that address is aligned and in the register's page,
  the instruction enters EX with its translation already made (`pg_q`, and
  `pg_*` registered with ID/EX). It goes straight to cycle B. The decisions
  read the same kinds of registers as before, through one more mux.
- **The source.** The page compared against is the lookup finishing in EX
  in that same cycle, if there is one, else `dp_*`. So two loads in a
  row to one page both skip cycle A.
- **The region check** is done in ID too, on the full address.
  Regions can be smaller than a page (the UART's is 256 bytes), so it
  cannot be cached per page.

Both the register and an instruction already carrying its translation
are dropped on anything that can change a translation's answer: a CSR
write, a trap, `mret` / `sret`, `sfence.vma`. That is the same list as
`IF_PAGE`'s. Dropping the copy riding with ID/EX matters when, say, a
`csrw satp` leaves EX at the same edge a load enters it.

A simulation-only check stops any run where an instruction translated in
ID does not have the address EX computes, or the PA and permissions the
D-TLB gives now, or the region attributes of its PA.

## Checks

| check | result |
|---|---|
| riscv-tests on the four board configurations | ALL PASS |
| mutant: no forwarding check (the ID address can be stale) | 10 tests fail |
| mutant: the PA taken from `dp_*` even when the page matched is the lookup finishing now | 4–5 tests fail |
| `tools/bench` | results verified, as above |
| U-Boot + Linux on the board configuration | LINUX: ALL PASS, no simulation-only check firing |
| timing | 51.9–59.1 MHz over 8 seeds, with Step 60 (see there) |

What is left: a load whose base comes from the instruction just ahead
(`addi a5, a5, 4; lw a4, 0(a5)`) still takes two cycles. Its address is
not known in ID. Multiplies take two cycles too (`MUL_2C`).
