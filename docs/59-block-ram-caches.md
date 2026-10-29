# Step 59 — Block-RAM caches: 16 + 16 KiB, and 50 MHz with margin

Step 58 got the board core to 50 MHz on the best of 18 placement seeds,
with 2.9 % margin. A profile of the Linux boot then showed where the
cycles went. Only a quarter of them retired instructions, and half were
spent waiting on 2 KiB caches. This step replaces both caches with
16 KiB block-RAM ones. A board-only option, `CACHE_BRAM`, selects them;
every other configuration keeps the old caches and their cycle counts.

The new caches turned out to be the timing fix as well. Once valid and
dirty moved into the tag block RAM, every one of nine placement seeds
routed at 55–58 MHz. The board stays at 50 MHz, now with 16.7 % margin
on the shipped seed instead of 2.9 %.

## The result

| | Step 58 | Step 59 |
|---|---|---|
| caches | 2 + 2 KiB, LUT RAM | **16 + 16 KiB, block RAM** |
| core clock after routing | 51.47 MHz on the best of 18 seeds (43.8–51.5) | **58.36 MHz** on the best of 9 (**55.3–58.4**: every seed passes 50) |
| margin at 50 MHz | 2.9 % | **16.7 %** |
| nextpnr LUT sites | 12,496 (35 %) | 11,119 (31 %) |
| flip-flops | 4,523 | 4,767 (13 %) |
| block RAM | 8 RAMB36 | 16 RAMB36 + 2 RAMB18 (of 60 / 120) |
| U-Boot + Linux, reset to shell | 374.8M cycles, 7.5 s | **304.4M cycles, 6.1 s** |
| CoreMark/MHz, Dhrystone DMIPS/MHz (memory latency 40) | 1.770, 0.276 | **1.854, 0.747** |

The bitstream is OpenZynq's `projects/riscv_linux/prebuilt/riscv_linux.bit`,
sha256 `3c60c10c…506c52de`, built with `--freq 50 --seed 6` (`OZ_SEED` in
`tools/rvlinux`). The U-Boot + Linux image is unchanged.

## Where the cycles went

`tb/boot_tb.v` with `-DPROFILE` prints the core's own counters at the end
of a run: `mcycle`, `minstret`, and the events for load-use, flush and
fetch bubbles and D-port stalls. It also prints the caches' hit and miss
counts. Pass it through `RVB_EXTRA="-DPROFILE" tools/rvlinux run --uboot
--board`. The output goes to `build/linux/sim.out`.

| cycles of the Linux boot | Step 58 (2 + 2 KiB) | Step 59 (16 + 16 KiB) |
|---|---|---|
| all | 424.3M | 337.5M |
| instructions retired | 100.4M | 100.2M |
| fetch bubbles (I-cache misses, new pages) | 121.7M | 64.0M |
| D-port stalls (D-cache misses, write-backs) | 90.2M | 68.1M |
| flush bubbles (taken branches) | 51.3M | 52.0M |
| I-cache misses / D-cache misses | 3.41M / 2.14M | 1.48M / 1.31M |

A simulation with the old caches simply made 16 KiB came to 332.2M. So
reading the arrays a cycle ahead, as block RAM needs, costs 1.5 %. Part
of the boot is set by the 115200-baud console, so the CPU benchmarks are
the cleaner measure. `tools/bench --hw brd-c2k-l40,brd-c16k-l40` runs
them on the board's core.

## Block RAM reads a cycle ahead

Block RAM takes an address at a clock edge and gives the data during the
next cycle. The old caches read their LUT-RAM arrays in the cycle of the
access. So the new ones read at the edge *before*, at an address the core
supplies:

- **`i_addr_next`**: the PC register's next value (`pc_d`), through the
  fetch page's registered translation: `{ip_ppn, pc_d[11:0]}`.
- **`d_addr_next`**: the physical address `XLATE_2C` registers for the load
  or store in EX (`xl_epa`). It is the D-port's address the moment that
  instruction enters MEM.

**`icache_b`** checks its read against the fetch in front of it (registered
index against the PC's, both from registers). If they differ (a redirect,
a new page), it reads again and answers a cycle later.

**`dcache_b`** cannot check that way. The D-port's address is a mux of MEM's
and the walker's, and arrives too late to compare. So the core promises
instead: **`d_hint_ok`** is up when the load or store in EX moves to MEM and
no walk holds or takes the port. Then the next request, if any, is at
`d_addr_next`. The cache trusts a read when it was the promised hint, or
when it was the request still waiting in front of it. The core holds a
request until `ready`. Anything else (a walk's PTE reads, an AMO's second
half) is read when it arrives, one cycle later. The tag compare uses the
registered tag of the address read, not the D-port's. A simulation-only
check stops any run in which a trusted read is not for the request. It
never fired in the riscv-tests, the boot tests or the Linux boot, and it
fires at once when the unit test breaks the promise on purpose.

In both caches a hint only ever changes how many cycles an access takes,
never what it returns.

**The rest of the design:**

- **Store, then read of the same line.** A store hit writes the merged line
  at an edge, and a read of that line at the same edge sees it without the
  stored word. That word and its position are kept in a register and put
  back in (the bypass).
- **Valid and dirty beside the tag.** The tag block RAM holds `{valid,
  dirty, tag}` entries:
  - a fill writes `{1, 0, tag}`;
  - a store hit writes `{1, 1, tag}`;
  - a `clean` write-back writes `{1, 0, tag}`.

  Reset and `fence.i`'s I-cache invalidation clear the entries one an edge,
  512 cycles, during which the cache answers nothing. An invalidation that
  lands during a fill lets the fill finish first.
- **Write-backs** go through a buffer that follows the line read until a
  write-back starts, so it has the victim at that edge.
- **Indexing.** Both caches are physically indexed, so 16 KiB
  direct-mapped needs no alias handling.

## The timing, build by build

The first version of these caches routed *slower* than Step 58: 46.5–49.3
MHz over six seeds. Each row below took out what the previous build's
seeds reported.

| change | 6–9 seeds |
|---|---|
| first block-RAM caches (valid and dirty in flip-flops, read at the hinted index) | 46.5–49.3 |
| valid read at the registered index instead (512:1 mux beside the RAM's output) | 39.7–46.8 |
| write-back buffer and XLATE_2C capture enables from registers only; one-word bypass | 43.4–48.3 |
| TLB fill writes no longer wait for the flush (`FAST_FILL`) | 40.8–50.7 |
| `LATE_TVAL`; dirty set a cycle late; miss-address, `clean`-counter enables from registers; constant compares as logic | 44.9–48.6 |
| the promised D hint (`d_hint_ok`); `trap_val` registered in pieces | 44.3–50.6 |
| **valid and dirty in the tag block RAM** | **55.3–58.4** |

The last row is the large one. The valid and dirty flip-flops (1,536)
each had their own set/clear decode, about 2,500 LUTs, plus three
512-to-1 read muxes, one of them on the D-cache's hit path. Moving them
into block RAM removed about 4,500 cells, a third of the design, and the
placer could then keep everything close.

Smaller changes along the way, board-only unless noted:

- **`FAST_FILL`** (`tlb.v`): a TLB entry's contents are only read through
  its valid bit. So a fill writes them whatever else happens that cycle.
  Before, the fill was the `else` of `if (rst || flush_all)`, and every
  entry's enable waited on `sfence.vma` → `ex_go` → the D-cache's hit. Only
  the round-robin pointer behaves differently, and only when a fill and an
  `sfence.vma` coincide, which is why it is a parameter.
- **`LATE_TVAL`** (`csr_s.v`): `mtval` and `stval` are written the cycle
  after a trap. Nothing can read them sooner: the cycle after a trap holds
  no instruction. The trap value's pieces are registered apart (the
  misaligned target next to the adders) and combined then.
  `rv32mx-ma_tgt` now checks `mtval` too, and a mutant that skips the late
  write fails it.
- **Constant compares as plain logic** (`lt_bits`, in `cpu_pipe_u` and
  `soc_boot`, every configuration): `<` against a constant became a carry
  chain. Written bit by bit, the synthesizer reduces it to a couple of
  LUTs. It still gives 0 mismatches in 4.8M checks against `a − base < size`.

## Checks

| check | result |
|---|---|
| `tb/dcache_b_tb.v`: 20,000 random reads and byte/half/word writes on 8 lines over 4 KiB, hints right, wrong and random, `hint_ok` as the core gives it, 50 `clean`s with memory checked after each | ALL PASS; mutants without the word bypass or the dirty bypass fail it, and a broken `hint_ok` stops it at once |
| `tb/icache_b_tb.v`: 30,000 fetches (runs and jumps), random hints, 127 `fence.i` invalidations at any cycle, inside fills too | ALL PASS |
| riscv-tests on `pipe_u_board`, `pipe_u_board_vm`, `pipe_c_board_vm`, `pipe_c_uni_board` (the last two with `icache_b` / `dcache_b`, 16 lines, so misses keep coming) | 59 · 59 · 59 · 60, ALL PASS |
| riscv-tests on `pipe_u`, `pipe_u_vm`, `pipe_c`, `pipe_c_vm`; `make cache` (all latencies), `cache-unit`, `tlb`, `pipe-u`, `pipe-u-sv`, `bench-counters` | ALL PASS |
| `make boot` | cycle counts identical to Step 58 |
| `make boot-board`, `rvlinux oz-sim`, `make ps-test`, `make pipe-u-board` | ALL PASS |
| U-Boot + Linux on the board configuration | LINUX: ALL PASS, 20 checks, the shell at cycle 304.4M, no simulation-only check firing |
| `tools/bench` | CoreMark/MHz 1.854, DMIPS/MHz 0.747, results verified |

## Where it stands

The shipped seed's worst path is forwarding → the ALU (`jalr`'s target) →
the registered redirect, at 17.1 ns. The next baud-exact clock above 50 MHz
is 55.56 MHz (IO PLL / 18, UART divisor 30). The best seeds would pass it
with about 5 % margin, as thin as Step 58's 50 MHz was, so the board stays
at 50.

What's left in work per clock, from Step 58's measurements: a branch
predictor whose lookup is registered (about +20 % CoreMark), and
single-cycle loads again for accesses in the same page as the last one
(up to +14 %).
