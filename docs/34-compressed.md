# Step 34 — The C extension (compressed instructions)

Every step so far has assumed something so basic it was invisible: instructions
are 32 bits and live at 4-byte-aligned addresses, so "fetch" means "read the
word at PC." The C extension breaks both assumptions at once. It adds 16-bit
encodings for the most common operations, which makes programs roughly 30%
smaller — and as a direct consequence, instructions become variable-length and
can start at any halfword, including *halfway through a memory word*. The
decoder turns out to be the easy part; the interesting work is in fetch.

## Why 16 bits is enough (sometimes)

RVC doesn't add any new operations. Each compressed instruction is defined as a
1:1 expansion of an existing base instruction, and it wins its bits back from
three observations about real code: most instructions use one of the 8
ABI-favoured registers (so 3-bit register fields suffice), the destination is
very often a source (`rd = rd op rs`), and immediates are usually small. So
`addi a0, a0, -3` fits in 16 bits as `c.addi`, while a rarer shape simply stays
32-bit. The encodings fall into three quadrants by the low two bits — `00`,
`01`, `10` are compressed; `11` means "this is a normal 32-bit instruction",
which is also exactly how the fetch unit tells them apart.

Because the mapping is 1:1, `rtl/rvc_expand.v` is a pure combinational
unscrambler: 16 bits in, the equivalent 32-bit instruction out. The core's
decoder, ALU, immgen, CSR unit — all byte-for-byte identical to `cpu_mc` —
never know compression exists. They are handed the expansion. The whole module
is immediate-bit permutations (RVC scatters immediate bits to keep register and
sign bits in fixed positions, a hardware-friendly choice that makes the decoder
look funny), plus the defined-illegal cases: the all-zero halfword,
`c.addi4spn` with a zero immediate, the RV64-only encodings, and the FP forms
we don't implement.

## The real problem: fetch

`rtl/cpu_mc_c.v` keeps the ROM as a 32-bit word memory — that's realistic; it's
how the BRAM is built — so with halfword-aligned PCs there are now four fetch
cases:

| pc[1] | instruction | where it lives |
|---|---|---|
| 0 | compressed | low half of word N |
| 0 | 32-bit | exactly word N |
| 1 | compressed | high half of word N |
| 1 | 32-bit | **high half of word N + low half of word N+1** |

The last row is the straddle, and it's why "unaligned fetch" is the headline of
this step. The core can't know an instruction straddles until it has read word
N and looked at two bits of it — by which time, in `cpu_mc`'s FSM, it is
already in EXEC. So EXEC grows a *discovery* outcome: if the halfword at PC has
`[1:0]==11` and `pc[1]==1`, the cycle commits nothing (regfile, CSR, store and
trap side effects are all gated off — the "instruction" decoded in that cycle
is half ours and half our neighbour's), latches the low half, and — in the same
cycle — presents word N+1's address to the ROM. The registered read means the
second word arrives next cycle, and execution proceeds with
`{word_N+1[15:0], saved_low_half}`. One extra cycle per straddling execution,
overlapping the address setup with discovery; a naive extra fetch state would
cost two.

Two small datapath consequences hide in the corners. The link address for
`c.jal`/`c.jalr` is **pc + 2**, not pc + 4 — the expansion can't encode that,
so the writeback path computes `pc + ilen`. And `mepc` must keep bit 1, since a
trap can now return to a halfword-aligned address; `jalr` likewise clears only
bit 0 (IALIGN=16). Our `csr.v` already stored `mepc` unmasked, so this worked
without modification — but it's the kind of assumption worth checking before
claiming C support.

## What the test shows

`make rvc` builds the *same C program* twice — `-march=rv32im_zicsr` and
`-march=rv32imc_zicsr` — and runs the first on the baseline SoC (`cpu_mc`) and
the second on the compressed SoC (`cpu_mc_c`), side by side in one testbench.
The program is deliberately branchy and call-heavy so gcc emits a wide spread
of RVC forms, and it fires an `ecall` four times so a trap and `mret`
round-trip through compressed code. A representative run:

```
   text: rv32im 424 bytes   ->   rv32imc 302 bytes      (29% smaller)
   checksum   : im=0x8e11aa5d  imc=0x8e11aa5d  (match)
   trap count : im=4  imc=4
   cycles     : im=3115  imc=3448
   compressed instrs run : 719
   straddling fetches    : 333  (1 extra cycle each)
```

The matching checksums are the real verification: 719 executed compressed
instructions across the forms gcc emits, every one expanded correctly, with 333
of the 32-bit instructions genuinely split across two ROM words (17 distinct
straddling sites in the image, starting in `crt0` itself). The testbench
asserts both counters are nonzero, so the hard path can't silently go
unexercised. And the cycle arithmetic closes exactly: 3115 + 333 = 3448.

That cycle line is worth being honest about: on *this* core, compressed code is
~10% **slower**, because the word-wide ROM charges one cycle per straddle and
nothing here rewards smaller code. The C extension's performance win on real
machines comes from what smaller code does to instruction caches and fetch
bandwidth — none of which this tutorial models. What it buys here is exactly
what's measured: 29% fewer code bytes for the same behaviour, which on a
BRAM-budgeted FPGA is often the difference between fitting and not.

## What's verified here

`make rvc` checks: identical checksums between the two builds, four trap
round-trips on each, both cores reaching SYSCON halt, at least one compressed
instruction and at least one straddling fetch on the C core, and prints the
code-size comparison. The baseline `cpu_mc` and every SoC built on it are
untouched (the C core is a separate `cpu_mc_c.v`), and the full regression
confirms nothing else moved.

## Honest status

- Coverage is "every RVC form gcc -O1 emits for this program," which is most of
  the catalogue but not a per-encoding directed test; a riscv-arch-test style
  compliance suite would be the rigorous upgrade.
- Misaligned-fetch *exceptions* aren't modelled: with C, the only illegal
  instruction address is an odd one, and this core can't generate odd PCs
  (`jalr` clears bit 0, branch/jump offsets are even by construction), so the
  check is moot rather than implemented.
- `rvc_expand` sits combinationally between the ROM output and the decoder, so
  it lengthens the EXEC-cycle timing path; in a pipelined core you'd put it in
  the fetch/decode boundary register. Verified in simulation only.
- The straddle costs a cycle because the ROM is one word wide. The standard fix
  is a small fetch buffer (read ahead one word, so the "other half" is usually
  already on hand) — the natural next improvement, and what real cores do.

## Takeaway

The C extension looks like a decoder feature and is actually a fetch feature.
The decoder is a stateless bit permutation precisely because every compressed
instruction is defined as an alias of a full one — the ISA spent its design
effort making hardware's life easy. What the core genuinely has to learn is
that "instruction" and "memory word" are no longer the same thing: the PC walks
in halfwords, a fetch can span two words, and a link or trap return address can
land between word boundaries. Get those three right and the rest of the machine
never notices that a third of its instructions are half-size — except that the
program shrank by 29%.
