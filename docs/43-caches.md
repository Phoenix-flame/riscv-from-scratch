# Step 43 — I-cache and D-cache in front of slow memory

Every core so far has run against memory that answers at once. The pipeline's
memories were combinational arrays, and the multi-cycle cores used block RAM
with a fixed one-cycle read. Neither is what a real system has. Main memory —
the Zynq's DDR, behind a controller and an AXI port — takes tens of cycles to
return the first word. It then streams the following words at about one per
cycle, because DRAM is organised in rows and bursts are what it is good at.

A core that pays that latency on every fetch and every load spends almost all
its time waiting. Caches are the answer. Step 42 made the unified pipeline's
ports *stall-capable* exactly so that this step could put caches on them
without touching the core: `cpu_pipe_u` is used here byte-for-byte unchanged.

## The slow memory

`rtl/mem_slow.v` is the DDR stand-in, and it models only the property that
matters:

```
accept (1 cycle) -> wait LATENCY cycles -> N beats, one word per cycle -> done
   burst=1 : a whole line (N = LINE_WORDS)        burst=0 : one word (N = 1)
```

A single word costs `LATENCY+2` cycles. An 8-word line costs `LATENCY+9`, so
eight words cost little more than one. A cache exploits exactly that asymmetry.
The model is synthesizable, with one registered read or write per beat.

## The caches

Both caches are direct-mapped with 32-byte lines. The defaults are 32 lines
(1 KiB) for the I-cache and 64 lines (2 KiB) for the D-cache. Each splits the
address as `| tag | index | word | byte |`, and each answers the core's
ready/valid port the same way:

- **Hit:** `ready` in the same cycle, with the word read straight out of the
  line array. The arrays are small and read combinationally (LUTRAM on an
  FPGA), so a hit costs the pipeline nothing.
- **Miss:** `ready` stays low while the line is fetched with one burst, and
  then the retried access hits.

**`rtl/icache.v`** is read-only, so it needs no dirty state. One detail comes
from the pipeline: the I-port may move to a new address while a refill is in
flight, because a branch redirected. The refill completes anyway, and the cache
then looks up whatever the PC is now. Instructions are never delivered for an
address that is no longer being asked for.

**`rtl/dcache.v`** is **write-back, write-allocate**:

| access | action |
|---|---|
| read hit | data the same cycle |
| write hit | bytes merged into the line at the clock edge; line marked **dirty**; memory untouched |
| miss, victim clean | burst-read the line (FILL), install it clean, retry hits |
| miss, victim dirty | burst-write the victim (WB), then FILL as above |
| write miss | same as a read miss (allocate), then the retried write hits |

Main memory only ever sees whole-line bursts, which is what a DDR controller
wants. The cache needs no request latch, because the core holds the address,
mask and data steady until `ready` (MEM is frozen, Step 42). The page walker
does the same, so **PTEs are read through the D-cache**. That matters: the
kernel writes page tables with ordinary stores, which sit *dirty in the
D-cache*, and the walker must see them. It does, because there is only one copy
on the data side.

MMIO bypasses the cache. `rtl/soc_pipe_c.v` decodes the address and sends UART,
timer and SYSCON accesses straight to the devices, ready in one cycle. Caching a
status register would be a bug.

## The SoC and the baseline

`rtl/soc_pipe_c.v` is Step 42's SoC with the ideal memories replaced by two
`mem_slow` instances, one for instructions and one for data (Harvard, as every
SoC here). A parameter picks what sits between core and memory:

- `CACHE_EN=1`: `icache` + `dcache`.
- `CACHE_EN=0`: `rtl/mem_bridge.v` on each port. Every access becomes its own
  single-word transaction, so this is what the core would see with no cache at
  all.

The two configurations differ only in the caches. Same core, same memory, same
latency.

## What the caches buy

`sw/cache_bench.c` has three phases that load the caches very differently:

- **reuse:** a 1 KiB array written once and read 8 times. It fits in the
  D-cache.
- **sort:** an insertion sort of 128 of those words. It is a tight loop with
  nearby loads and stores, and heavy instruction reuse.
- **stream:** an 8 KiB array, four times the D-cache, read one word per line,
  twice. Every one of those loads misses.

The phases are timed separately: the testbench stamps the cycle count at each
line the program prints. The benchmark also compiles natively (`-DHOST`), and
each run's UART output must equal the host's (`tb/cache_bench_expected.txt`),
so correctness is not judged by any core in this project.

`make cache` runs it on three SoCs side by side at each latency. **ideal** is
Step 42's combinational memory, the upper bound. **cached** and **none** are
the two configurations above:

```
latency 1            reuse      sort    stream     total   CPI
  ideal              19835     52340     16891     89876  1.55
  cached             21081     53057     29893    104995  1.82
  none              105069    312330     96936    518061  9.01     speedup  4.93x

latency 10
  cached             22143     53741     39946    116920  2.02
  none              262668    780825    242340   1295148 22.53     speedup 11.07x

latency 40
  cached             25683     56021     73456    156670  2.71
  none              787998   2342475    727020   3885438 67.59     speedup 24.80x

  I$ 183 misses     D$ 848 misses, 306 writebacks      (every latency)
```

(`make cache` also prints latencies 5 and 20, and `CACHE_LATS=...` picks
others.)

Three things stand out:

1. **Without caches, latency is everything.** Every fetch pays it, so CPI
   tracks latency almost one for one: 9 → 23 → 68. Even at latency 1 the
   bridge's handshake costs ~5 cycles per access. (That is a little unkind to
   the baseline, but the gap at real DDR latencies is not about the
   handshake.)
2. **With caches, latency hardly matters where there is locality.** *reuse*
   and *sort* stay within 30% and 7% of ideal even at latency 40. Their misses
   happen once, and every later access hits.
3. **The cost that is left is exactly misses × latency.** Going from latency 10
   to 40 adds 39,750 cycles, which is 1,325 per cycle of latency. The I- and
   D-misses and write-backs add up to 183 + 848 + 306 = 1,337 transactions.
   Each transaction costs `LATENCY + ~9` cycles, and that is the whole penalty.
   *stream*, which is built to defeat the cache, carries most of it.

The I-cache misses only 183 times for the whole run. The program is 2.1 KiB
against a 1 KiB I-cache, but its loops are small. The 848 D-misses are almost
all *stream*: 256 lines to initialise the array, plus 2 × 256 lines read. The
306 write-backs are the dirty lines that initialisation left behind.

## Correctness

A cache that is fast but occasionally returns a stale word is worse than none,
so each part is tested several ways:

- **`make cache-unit`** (`tb/dcache_tb.v`): the D-cache alone against a flat
  reference model. It uses a deliberately tiny cache (8 × 4 words = 128 bytes)
  over 4 KiB. Half the accesses go to a hot window the size of the cache and
  half go anywhere, so hits, write hits, dirty evictions and write-backs are
  all constant. That is 20,000 random reads and byte, halfword and word writes,
  each held until `ready` as the core holds them, with random idle gaps. Every
  read is checked, and at the end every word is checked through cache-or-memory.

  ```
  D-cache unit: 10047 reads, 9953 writes, 14598 misses, 8169 writebacks, 243276 cycles
  DCACHE: ALL PASS (every read and every final word matches the model)
  ```

  The test has teeth. A cache that forgets to set the dirty bit fails 9,864
  checks.
- **The benchmark**, as above: byte-exact against the host at five latencies.
- **The MMU programs through tiny caches** (`tb/cache_sys_tb.v`). The Step 41
  TLB demo and Step 38's isolated-processes scheduler run on 256-byte I- and
  D-caches at latency 7. Code, data, page tables and stacks all fight for the
  same lines. Page walks read PTEs through the D-cache, while the kernel's PTE
  updates sit dirty in it, and the stale-translation and isolation checks still
  pass. Results are read through `peek()`, because the newest copy of a word
  may still be in the cache.
- **riscv-tests through the caches** (`tb/rvtest_pc_tb.v`). They run on 512-byte
  caches at latency 5, both as `pipe_c` (body in M) and as `pipe_c_vm` (body in
  U with Sv32 on). Both pass 58/58 across rv32ui/um/ua, with the usual
  `fence_i` / `ma_data` gaps.

## Honest status

- Verified in simulation only. The caches are written to be synthesizable
  (LUTRAM-sized arrays, registered state, one fill per miss), but no bitstream
  has been built.
- **Combinational hit path.** A same-cycle hit needs an asynchronous read of the
  tag and data arrays, which is LUTRAM territory. That is fine at 1–4 KiB. A
  block-RAM-sized cache has a registered read, and needs either a pipelined
  lookup (IF1/IF2, MEM1/MEM2) or a one-cycle hit latency the core would see as
  a stall. That is the next microarchitecture step.
- **Harvard backing memories.** Instructions and data have separate `mem_slow`
  instances, as every SoC in this project keeps the two address spaces apart.
  One real DDR would need a two-master arbiter in front of a single memory
  (and then `fence.i` could be made to work by writing back the D-cache and
  invalidating the I-cache). The caches already speak in whole-line bursts,
  which is what that arbiter and an AXI4 burst master (Step 36's natural
  follow-up) would carry.
- Direct-mapped only: no associativity, no replacement policy beyond "the
  index decides". No prefetch, and no critical-word-first. The refill waits
  for the whole line before the core sees any of it.
- A miss blocks. While the D-cache refills, the pipeline is frozen. No
  hit-under-miss.
- The cache's hit/miss counters are plain registers for the testbench. A real
  design would expose them as `mhpmcounter` CSRs.

## Takeaway

A cache turns memory latency from a per-access cost into a per-miss cost. With
these two small caches, the same core on the same slow memory goes from 22 CPI
to 2 at a latency of 10, and from 68 to 2.7 at 40. What remains is a simple
product, misses × latency, so the next gains come from fewer misses (bigger or
associative caches) or cheaper ones (critical-word-first, prefetch, a wider
burst). Because the core already spoke ready/valid, none of it needed a change
to the pipeline.
