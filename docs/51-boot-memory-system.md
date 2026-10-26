# Step 51 — Memory for the boot platform: caches, block RAM, DDR

After Step 50, `soc_boot` had everything a kernel expects of the hardware
except memory it could use. Its ROM and RAM were ideal combinational
arrays: fine for simulation, but not something an FPGA builds. And its
256 KiB is a hundredth of what Linux wants. This step gives the platform
real memory systems, selected by one parameter, `MEMSYS`:

| `MEMSYS` | memory | what it is for |
|---|---|---|
| 0 | ideal arrays (Steps 49–50, unchanged) | the fastest simulation |
| 1 | I-cache + D-cache, both refilling from **block RAM**: the 16 KiB ROM and the RAM | the board: everything in the PL |
| 2 | the same caches; ROM and the firmware's 16 KiB in block RAM; the rest of RAM in **DDR over an AXI4 burst master** | megabytes: 64 MiB in the test |

Most of the machinery already existed. The I-cache and the write-back
D-cache are Step 43's, and the block-RAM sequencer is Step 45's
`oz_burst_mem`. What is new is what one memory behind two caches demands:
the two must take turns on it (`line_arb`), and `FENCE.I` must make them
agree. DDR also needs an AXI4 master that speaks in bursts
(`axi4_line_master`).

```
make boot          # all three memory systems, one transcript
make boot-board    # the board build: 128 KiB, 115200 baud
make axi4-line     # the burst master against a stalling AXI slave
make boot-synth    # Yosys: fpga_top_boot for the Zynq-7010
```

## One line port, routed

Both caches move whole 32-byte lines with `mem_slow`'s protocol: hold
`req` until a one-cycle `done`. `line_arb` grants one requester at a
time and holds the grant until that transaction's `done`. The D side
wins a tie, because a D-cache miss freezes the whole pipeline while an
I-cache miss only starves IF. Behind the arbiter, a line goes to one of
three places, chosen by its address:

| line address | goes to |
|---|---|
| boot ROM `0x0000_1000` + 16 KiB | ROM block RAM, through `oz_burst_mem` (read-only) |
| `0x8000_0000` + `OCM_WORDS`×4 (`MEMSYS 2`; all of RAM for `MEMSYS 1`) | RAM block RAM, through `oz_burst_mem` |
| the rest of RAM (`MEMSYS 2`) | `axi4_line_master` → AXI4 → DDR |

MMIO bypasses the D-cache, as on Step 43's `soc_pipe_c`, and answers in
one cycle. The ROM is cached on both sides. Its code goes through the
I-cache, and its read-only data (the strings, the embedded DTB) goes
through the D-cache. Step 50's PMA check stops any store to it before the
cache sees one, so a ROM line is never dirty.

## FENCE.I with two caches

On ideal memory, Step 49's `FENCE.I` only had to refetch what followed
it. Behind caches that is not enough. A program the ROM has just written
can be sitting in dirty D-cache lines that memory has never seen, and the
I-cache can still hold a copy of the old bytes at the same address. The
fence now involves the SoC:

1. The core holds the `FENCE.I` in EX and raises `fencei_req`. It asks
   only when MEM is not frozen, so every older store has reached the
   D-cache.
2. The D-cache **cleans**: it walks its lines and writes each dirty one
   back, one burst each, keeping them valid. It starts only between
   accesses.
3. When the clean is done, the I-cache is **invalidated** in one cycle,
   and `fencei_ack` lets the fence leave EX. The redirect behind it then
   misses and refills from memory, which now holds the new code.

The order matters, and there is one subtle case. An I-cache refill can
already be in flight when the invalidate arrives, for a line that was
read from memory before the write-back reached it. That refill still
completes, because a burst cannot be dropped halfway, but it is not
installed (`drop` in `icache.v`). SoCs without coherence to maintain tie
`fencei_ack` to 1, and the fence costs what it did before.

`make boot` counts the cost: five `FENCE.I`s (one per payload the ROM
starts, plus `dtdemo`'s own test), and a few thousand cycles in total
waiting for the caches, mostly the D-cache's walk over its 64 lines. Two
negative controls show the maintenance is what makes this work. With
`fencei_ack` tied to 1 in the cached `soc_boot`, `dtdemo` starts and
then dies a few lines in: the parts of it already evicted to memory run,
the rest is stale. riscv-tests' `fence_i`, run on a new core
`pipe_c_uni` (both caches over one memory, `tb/rvtest_pc_tb.v
-DRVT_UNIFIED`), fails at sub-test 2. With the maintenance it passes,
and the whole suite passes 91/91 through the unified caches.

## DDR: an AXI4 burst master

Step 36's AXI4-Lite master moved a word per handshake. DDR wants bursts,
and a cache already thinks in lines, so `axi4_line_master` turns each
line request into one AXI4 INCR burst of 8 beats, 4 bytes each:

- **read:** AR, then 8 R beats;
- **write:** AW and 8 W beats offered together, `WLAST` on the last,
  then one B response.

One transaction is in flight at a time, with ID 0, so nothing returns
out of order. A non-OKAY response is latched in `err`. `ADDR_OFFSET`
places the window anywhere in the slave's map; on a Zynq, that is
somewhere in PS DDR behind an `S_AXI_HP` port. Those ports speak AXI3,
which differs from this only in `WID` (0 here) and allows the same
8-beat bursts.

`tb/axi4_mem.v` stands in for the DDR controller. It has a latency of
`LATENCY` cycles to the first beat (and to the B response), then one beat
per cycle. With `STALL = 1`, every channel drops `ready` or `valid` on
about a quarter of the cycles. Addresses outside its window answer
SLVERR, and it counts protocol errors: `WLAST` in the wrong place, or an
unsupported burst type or size. `make axi4-line` runs the master against
it: 64 random lines written, read back, a quarter rewritten, read again;
a read outside the window raises `err`. The testbench also checks AXI's
rule that a `valid`, once raised, stays up with stable payload until
`ready`. There are no mismatches and no protocol errors. At latency 7
with stalls, a line costs about 23 cycles each way.

## Two problems the DDR run found

**The receive loop fell behind again.** The first DDR run of `make boot`
lost bytes on the very first image: the FIFO filled to 16 of 16. Step 49
had made the ROM keep up with a UART that has no flow control. Over
DDR, the D-cache's misses broke that again, and the cause was the cache
index. The 2 KiB D-cache is direct-mapped: 64 lines, indexed by address
bits [10:5]. The receive loop touched about five lines per byte, and two
pairs of them collided:

| line | index | collides with |
|---|---|---|
| `0x0000_3f80`: the ROM's `rom_uart` descriptor | 60 | `0x8000_3f80`: the ROM's stack |
| `0x0000_4000`: Step 49's CRC nibble table | 0 | `0x8000_4000`: the payload being received |

Every byte could evict the destination line just to read the CRC table.
Each eviction cost a DDR write-back plus a refill, more than the 160
cycles a byte takes to arrive. Over block RAM a miss costs about 10
cycles, which is why `MEMSYS 1` had passed.

The table that made the CRC fast in Step 49 was itself the problem: a
table lookup is a memory access, and behind a cache its line can collide
with anything. The fix is a receive loop (`rx_bytes()` in `rom_main.c`)
that touches no memory except the UART and the destination. The UART is
at a constant address, the error bits stay in a register, and the CRC is
the bit-serial one again, but now folded in per byte, which the Step 49
fix had already made affordable: eight shift-and-xor steps a byte, in
registers, well inside the 160 cycles available.

**On-chip RAM for the firmware.** In `MEMSYS 2`, the firmware's 16 KiB
at the bottom of RAM stays in block RAM, like the Zynq's OCM. That
region is already marked `reserved-memory` in the DT; it holds the ROM's
variables and stack, and later the resident SBI. This is a speed-up, not
the fix. With the receive loop fixed and the firmware's data in DDR too,
the run still passes, at 11.42M cycles and a FIFO peak of 9, against
10.60M and 8 with on-chip RAM. Keeping the firmware off DDR also keeps
every SBI call and timer interrupt off DDR's latency.

## The board build

`rtl/fpga_top_boot.v` is `soc_boot` with `MEMSYS = 1` and 128 KiB of RAM,
for the OpenZynq / Mitra-7010 board. With the 16 KiB ROM that is 144 KiB
of block RAM; the Zynq-7010 has 240 KiB. The pins are the ones
`tools/rvgen` uses for this board: 50 MHz on U18, reset (K1) on U19,
LEDs on R19 and V13, UART TX on J18. `make boot-board` builds a board
ROM and DT with UART divisor 27, which gives 115740 baud, within 0.5 % of
115200. The DT's `current-speed` says so, and the RAM size is still
probed.

The same make target simulates exactly that configuration: block RAM,
128 KiB, 432 clocks per bit. The banner reports 128 KiB, a corrupted
image is rejected, and `libc_demo` loads and runs; this takes 20.9M
cycles, 0.42 s of real time at 50 MHz.

`constraints/openzynq_boot.xdc` leaves **UART RX** as a placeholder. No
RX pin is defined anywhere in this repository, and the board's pinout
lives in OpenZynq (`boards/mitra7010/pinout.md`). Vivado stops at the
placeholder until someone chooses a pin, rather than this file guessing
one.

## What `make boot` shows now

The same seven chunks and the same 230-line transcript, on all three
memory systems. The transcript template has placeholders (`{DTB}`,
`{RAM_SIZE}`, `{RAM_KIB}`) for what depends on the RAM size.

| | ideal | caches + block RAM | caches + DDR (64 MiB) |
|---|---:|---:|---:|
| cycles | 7,009,113 | 9,005,071 | 10,597,431 |
| RAM the ROM probes (and the DT reports) | 256 KiB | 256 KiB | 64 MiB |
| RX FIFO peak (of 16) | 4 | 5 | 8 |
| `FENCE.I`s / cycles waiting for the caches | 5 / 0 | 5 / 2,753 | 5 / 8,251 |

About 5.9M of the cycles are the serial line itself: 27.7 KB in and
8.9 KB out, at 160 cycles a byte. The rest is the programs, and the
caches' misses are what separates the three columns. A `FENCE.I` costs
about 550 cycles over block RAM and 1,650 over DDR. That is the D-cache's
walk over its 64 lines, plus writing back whatever is still dirty: the
payload the ROM just stored. The FIFO peak includes `kdemo`'s receive,
whose trigger level lets four characters collect before it takes an
interrupt; the peak never comes near 16 on any memory system.

The board build adds the fourth configuration (`make boot-board`): a
shorter stream at 115200 baud, 20.9M cycles.

## What's verified here

- `make boot`, on all three memory systems. Each one passes the full
  transcript, the `dtc` re-read of the DTB, and a clean power-off. Every
  payload is written through the D-cache and fetched through the
  I-cache, so the `FENCE.I` maintenance is in the path of every boot;
  without it, the run breaks.
- `make boot-board`: the board configuration end to end at its real baud
  rate.
- `make axi4-line`: data, error responses and AXI handshake rules
  against a stalling slave.
- `tools/rvtests --core pipe_c_uni`: 91/91 through unified caches,
  including `fence_i`, which fails without the maintenance.
- Regressions after the shared-file changes (`cpu_pipe_u`'s
  `fencei_req` / `fencei_ack`, the caches' `inval` / `clean`):
  `cache-unit`, `cache`, `pipe-u`, `pipe-u-sv`, `bench-counters`,
  `smode`, `tlb`, `vec`, all nine `rvgen-all` presets, and riscv-tests
  on `pipe_u_uni`.

## Cost

`make boot-synth`: Yosys 0.33, `synth_xilinx -flatten -abc9 -arch xc7`,
`fpga_top_boot` as a whole (the core with M/S/U, the MMU, Zb*, the
predictor and the counters; 2 + 2 KiB caches; the PLIC, CLINT and 16550;
16 KiB ROM and 128 KiB RAM). It took 53 minutes, most of it in ABC.

| | used | Zynq-7010 | |
|---|---:|---:|---|
| LUTs (logic) | 14,009 | 17,600 | 80 % |
| LUTs as distributed RAM | ~990 | 6,000 | mostly the cache lines and tags |
| flip-flops | 7,347 | 35,200 | 21 % |
| RAMB36 | 36 | 60 | 4 for the ROM, 32 for the RAM |
| CARRY4 | 1,240 | 4,400 | |

It fits, with about 15 % of the LUTs to spare. Placement and timing at
50 MHz are the open question: no place-and-route tool was run. Of what
Steps 49–51 added, the PLIC is the largest single block (~1,070 LUTs,
Step 50). The two 2 KiB caches live in distributed RAM because their
lookup is combinational; a registered, block-RAM-sized lookup would move
them out of the LUTs, at the cost of a cycle on every hit.

## Honest status

- Nothing here has run on hardware. The board build synthesizes with
  Yosys and simulates at its real baud rate; timing has not been closed
  at 50 MHz, and no bitstream has been made.
- DDR is verified against an AXI4 model, not the Zynq's controller. No
  PS7 / `S_AXI_HP` wrapper exists in this repository yet. Putting
  `MEMSYS 2` on the board means instantiating the PS with an HP port
  (AXI3: the master's `WID` is 0) and a DDR configuration.
- The caches are Step 43's: direct-mapped, 2 KiB each. That is small for
  a kernel, and conflict misses are exactly what bit the receive loop.
  Set associativity is the natural next step. The lines are LUT RAM with
  a combinational read.
- `FENCE.I` cleans the whole D-cache and invalidates the whole I-cache.
  There is no per-address maintenance, no `Zicbom`, and no DMA
  coherence; there is no DMA.
- Linux is still not running here. That needs a kernel configured and
  built for this platform, and, on the board, the DDR hookup; in
  simulation, 64 MiB of DDR is now available to it.

## Takeaway

A cache adds two problems to every access: where else that line might
live, and which other line it might push out. The boot ROM met both. The
code it had just stored sat in dirty D-cache lines that the I-cache could
not see until `FENCE.I` became a handshake with the memory system. And
the lookup table it had added to keep up with the UART shared an index
with the buffer it was filling. Neither problem shows up on ideal
memory, and over block RAM only the first did.

## Files

| file | |
|---|---|
| `rtl/soc_boot.v` | `MEMSYS` 0 / 1 / 2: caches, line routing, block RAM, the AXI4 port; the `FENCE.I` controller |
| `rtl/line_arb.v` | two cache refill ports onto one line memory |
| `rtl/axi4_line_master.v`, `tb/axi4_mem.v`, `tb/axi4_line_tb.v` | lines as AXI4 bursts; the stalling DDR model; their test (`make axi4-line`) |
| `rtl/icache.v`, `rtl/dcache.v` | `inval` (dropping an in-flight refill) and `clean` / `clean_done` |
| `rtl/cpu_pipe_u.v` | `fencei_req` / `fencei_ack`: the fence waits in EX |
| `rtl/soc_pipe_u.v`, `rtl/soc_pipe_c.v`, `rtl/oz/oz_rv_soc.v`, `tb/rvtest_p[uc]_tb.v`, `tb/dcache_tb.v` | tie the new ports off |
| `rtl/fpga_top_boot.v`, `constraints/openzynq_boot.xdc` | the board top and its pins (UART RX to be chosen) |
| `sw/boot/rom_main.c`, `lib.h`, `lib.c`, `platform.h` | the register-only receive loop; bit-serial CRC; `UART_DIVISOR` per build |
| `sw/boot/kdemo.c` | interrupt-count check that does not depend on cache timing |
| `tb/boot_tb.v`, `tools/rvboot`, `tb/boot_expected.txt` | `MEMSYS` / `RAM_WORDS` / `DIVISOR`; the DDR model; one transcript for every RAM size; `--memsys` |
| `tb/rvtest_pc_tb.v`, `tools/rvtests` | `RVT_UNIFIED`, core `pipe_c_uni` |
| `Makefile` | `axi4-line`, `boot-board`, `boot-synth` |
