# Step 57 — Trying to build the bitstream, and the divider that came out of it

Steps 54–56 got the core to the Mitra-7010 in simulation. This step is the
first attempt to turn `fpga_top_linux` into a bitstream with OpenZynq's
open flow (Yosys 0.68, nextpnr-xilinx 0.9.3, prjxray). **It did not
produce a `.bit`.** What it did produce: the reason, one fix that was
worth making, and a record of how to reproduce the attempt.

## Where it stands

| step | result |
|---|---|
| build OpenZynq's toolchain image | works, with two workarounds (below) |
| chip database for the xc7z010 | works (55 MB, a few minutes) |
| Yosys synthesis | works: about 33 minutes with ABC9 |
| nextpnr placement, original design | **fails**: no legal placement |
| nextpnr placement, with the iterative divider | places; 88 cells left stranded |
| nextpnr routing | **fails**: `No wire found for port A1 on destination cell …` |
| timing, before routing | 15.5 MHz for the 50 MHz core clock (12.2 MHz with plain ABC) |

So there is no bitstream, and even a routed one would be predicted not to
meet 50 MHz by this tool's timing model.

## The area: the ALU's dividers

The first run failed at placement ("Unable to find legal placement for
cell … check constraints and utilisation"). Yosys reported about 15,100
cells, about 85 % of the part's 17,600 LUTs once the distributed RAM is
included. nextpnr then packed 23,923 LUT cells, not 15,000: it adds a
route-through `LUT1` where a flip-flop or a carry output has no LUT in
front of it, 8,949 of them, which is roughly seven per `CARRY4`. That is
24,978 of its 35,200 LUT sites (71 %, where a 5-input LUT can share a
6-LUT only if the pair's inputs fit), too many to place.

A per-module breakdown put the ALU first by a wide margin. `alu.v`
writes `DIV`, `DIVU`, `REM` and `REMU` as Verilog `/` and `%`, which
synthesises to combinational array dividers (its header says so: "a real
core uses a multi-cycle divider"). They were most of the LUTs, and most of
the carry chains that nextpnr inflates.

### The fix: `DIV_ITER`

`div_iter` (at the bottom of `alu.v`) is a restoring divider that yields
one quotient bit a cycle on the unsigned magnitudes, with the signs and
RV32M's special cases (x/0 = −1, x%0 = x, −2³¹/−1) applied around it. A
divide takes 33 cycles from entering EX to leaving it. `cpu_pipe_u`'s
`DIV_ITER` parameter selects it (default 0, so every other configuration is
unchanged and cycle-identical). A divide in EX holds the instruction
through the existing `ex_hold`, the way a vector op or a page-table walk
does, and a flush or trap while it runs aborts it. `soc_boot` passes the
parameter on, and `fpga_top_linux` and the `board-ddr` test variant turn it
on.

| | array dividers | `DIV_ITER` |
|---|---|---|
| nextpnr LUT sites (of 35,200) | 24,978 (71 %) | 16,991 (48 %) |
| `CARRY4` | 1,277 | 480 |
| route-through `LUT1` | 8,949 | 3,386 |
| placement | fails | completes |

Checks:

- `make div-iter` (`tb/div_iter_tb.v`) runs 4,579 divisions through the
  handshake against the ALU's own array divider: corners (0, ±1, 2³¹,
  2³¹−1, divide by zero, the signed overflow) in all four operations, 4,000
  random pairs of random width, a mid-run abort, an unfrozen hold, and a
  frozen first cycle. Each takes exactly 33 cycles. A mutant with the wrong
  remainder sign fails it. (The overflow special case is redundant:
  the algorithm gets it right on its own. It stays, for clarity.)
- `tools/rvtests --core pipe_u_div` and `pipe_c_uni_div` run the whole
  official suite on the pipeline with `DIV_ITER=1`: `rv32um` 8/8 in both,
  `rv32ui`/`ua`/`zb*` as before, with the same documented gaps as their
  baselines (`fence_i`, `ma_data`).
- `make boot-board` passes in the Linux board build (the `board-ddr`
  variant). `tools/rvlinux all --board`, the same Linux boot as Step 54
  with the iterative divider, reaches its shell and passes all 17 output
  checks: 245.7M cycles in all, 176M from kernel entry to the prompt.

What it costs: a divide is 33 cycles instead of 1. Kernel entry to the
shell prompt is 176M cycles, 3.5 s at 50 MHz, which is what Step 54
reported without it.

## What still stops it

1. **nextpnr-xilinx's post-placement repair.** After placing, its
   `fixupPlacement` looks for cells the placer left on an invalid BEL, such
   as a LUT6 on a 5-input LUT site, and moves each to the nearest valid
   free one. At this density it logs `post-place repair: no valid
   placement for …` for 88 cells and leaves them. The router then can't
   find a wire for their input (`No wire found for port A1`) and aborts.
   Plain ABC instead of ABC9 gives the same error at 63 % of the sites, so
   it is not an ABC9 artefact. I read the source of the repair
   (`xilinx/arch_place.cc`, tag 0.9.3) but did not find a way around it.
2. **Timing.** nextpnr's estimate after placement is 15.5 MHz for the core
   clock (`u_ps7.hp0_aclk`, which is the 50 MHz PL oscillator, because the
   core and `S_AXI_HP0` share it), against 105 MHz for the GP0 clock.
   The long path is the whole EX stage in one cycle: forwarding, the ALU,
   the address, the D-TLB lookup and the D-cache tag compare. The
   estimate is before routing, and prjxray's timing data is conservative,
   but a factor of three is not within what routing recovers. The core
   would need a slower clock, with `PLAT_CLOCK_HZ`, the UART divisor and
   the device tree to match, or a shorter critical path.

What would probably help, untried here because each attempt is about 40
minutes:

- Less logic. `zb_unit` (Zba/Zbb/Zbc/Zbs, about 2,000 LUTs) is unused by
  the kernel, which is built for `rv32ima`; the branch predictor is about
  1,700 LUTs and 3,800 flip-flops; the TLBs are about 1,300 LUTs each.
  Each would be a configuration parameter on the board build, as `DIV_ITER`
  is.
- A slower core clock, from PS `FCLK_CLK1` (24 MHz in the board preset) or
  a fabric divider.
- Vivado. It packs a design like this far better. The board top
  instantiates the bare `PS7` primitive with its DDR and MIO pins unbound
  (that is how OpenZynq's flow works), which Vivado's DRC will reject, so it
  would need a block-design wrapper. Not attempted.

## Reproducing the toolchain build

OpenZynq's `docker/Dockerfile` does not build today, for reasons that have
nothing to do with this design:

- It downloads openXC7's installer script from `main`, which has since
  moved to a different engine (Bazel, a himbaechel build of nextpnr), so
  the image no longer holds `nextpnr-xilinx`, `bbasm` and `bbaexport.py`
  where the Makefile expects them. Pinning the installer URL to commit
  `0d8d6d84cb40fd546719df225ba3717165b2617f` (the one that matches the
  versions the Dockerfile's own comments name) gives the image the Makefile
  was written for. That change is in the OpenZynq checkout.
- Behind a TLS-intercepting proxy, the build needs the proxy's CA in every
  stage and `--network host`; it is a sandbox matter, not part of the repo.

## Files

`rtl/alu.v` (`div_iter`, and `DIV_ITER` on `alu`), `rtl/cpu_pipe_u.v`,
`rtl/soc_boot.v`, `rtl/fpga_top_linux.v`, `tb/div_iter_tb.v`,
`tb/rvtest_pu_tb.v` and `tb/rvtest_pc_tb.v` (`RVT_DIV_ITER`),
`tools/rvtests` (`pipe_u_div`, `pipe_c_uni_div`), `tools/rvboot`
(`board-ddr` sets `div_iter`). `make div-iter`.
