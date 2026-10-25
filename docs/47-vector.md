# Step 47 — The vector extension: Zve32x on the pipeline

RISC-V's vector extension (RVV 1.0) is the ISA's answer to SIMD. It is not a
fixed-width SIMD instruction set. The program asks the hardware how many
elements it can do (`vsetvli`) and gets back `vl`. It then processes `vl`
elements with each vector instruction and loops. The same binary runs on a
64-bit implementation and on a 1024-bit one; only the trip count changes. This
step adds a vector unit to `cpu_pipe_u` for the embedded integer profile
**Zve32x**: 32 vector registers of `VLEN` bits (64, 128 or 256 here), elements
of 8, 16 or 32 bits, no floating point and no 64-bit elements.

The hardware is deliberately the simplest one that is architecturally
complete: **blocking and element-serial**. One vector instruction occupies EX
and does one element per clock until it is finished. The value of the step is
in the parts that the width of the datapath does not change, and that a wider
unit still has to get right:

- `vsetvl*`, `vtype` legality, VLMAX;
- register groups (LMUL), fractional LMUL and EMUL;
- masks and tail elements;
- `vstart` and **precise traps in the middle of a vector instruction**;
- fault-only-first loads;
- vector memory accesses translated by the MMU like any other access;
- `mstatus.VS` context-switch state.

```
         ID ── decode: OP-V, LOAD-FP/STORE-FP vector forms ── legality
          │
         EX ──────────── scalar path ─────────────┐
          │  vector:  ex_hold while busy          │
          │  ┌──────────────────────────────┐     │
          └─►│ vec_unit                     │     │
             │  VRF 32 × VLEN (LUT RAM)     │     │
             │  element FSM, ALU, multiplier│     │
             │  one element / clock         │──► rd (vsetvl, vmv.x.s, vcpop, vfirst)
             └──────┬───────────────────────┘
                    │ element VA
               D-TLB / walker ──► D-port   (priority: walker > vector > MEM)
```

## What is implemented

| class | instructions |
|---|---|
| configuration | `vsetvli vsetivli vsetvl` (SEW 8/16/32, LMUL 1/8 … 8, `vill`) |
| loads / stores | unit-stride `vle/vse{8,16,32}`, strided `vlse/vsse`, indexed `vluxei/vloxei/vsuxei/vsoxei`, mask `vlm/vsm`, fault-only-first `vle*ff`, whole-register `vl<n>re*/vs<n>r` |
| integer | `vadd vsub vrsub vand vor vxor vsll vsrl vsra vminu vmin vmaxu vmax vmerge vmv.v.[vxi] vmv<n>r.v` (`.vv/.vx/.vi` where defined) |
| multiply | `vmul vmulh vmulhu vmulhsu vmacc vnmsac vmadd vnmsub` |
| compare → mask | `vmseq vmsne vmsltu vmslt vmsleu vmsle vmsgtu vmsgt` |
| permute | `vslideup vslidedown vslide1up vslide1down`, `vmv.x.s vmv.s.x` |
| reductions | `vredsum vredand vredor vredxor vredminu vredmin vredmaxu vredmax` |
| mask | `vmand vmnand vmandn vmxor vmor vmnor vmorn vmxnor vcpop.m vfirst.m vid.v`; every op can be masked by `v0.t` |
| CSRs | `vstart vxsat vxrm vcsr vl vtype vlenb`; `mstatus.VS` / `SD` |

**Not implemented**: fixed-point (`vsadd vaadd vsmul vssr* vnclip`), divide,
widening/narrowing, segment loads/stores (`nf > 0`), `vrgather`,
`vcompress`, `viota` and the `vmsbf/vmsif/vmsof` family. These decode as
**illegal instructions** and trap; they do not run as something else. So this
is a subset of Zve32x, which formally includes fixed-point and divide. A trap
handler could emulate the missing instructions.

Tail elements and masked-off elements are always left **undisturbed**. The
spec allows that under either policy: "agnostic" means "undisturbed or all
ones, implementer's choice".

## The unit: `rtl/vec_unit.v`

**Register file.** `32 × VLEN` bits as an array of 32-bit words,
`VLEN/32` words per register. Element *i* of register *r* at width *e* bytes
is in word `r·VLEN/32 + (i·e)/4`, at byte lane `(i·e) mod 4`. Mask bit *i* is
bit *i mod 32* of word `r·VLEN/32 + i/32`. Register groups (LMUL > 1) are
consecutive registers, so this one formula covers them without a special case.
The VRF has four combinational read ports (vs2, vs1, the old vd, and v0 for
the mask) and one write port. That shape maps to LUT RAM.

**Sequencer.** `IDLE → INIT → RUN → (FINAL) → DONE`.

- **INIT** latches the scalar operands, loads a reduction's accumulator from
  `vs1[0]` and finishes `vmv.x.s` / `vmv.s.x` on its own.
- **RUN** walks the elements `idx = vstart … evl-1`. For each one it reads the
  operands, computes, and writes the element back into its word of vd
  (read-modify-write within the word).
- Compares and mask logic collect their result bits in a VLEN-bit register,
  and **FINAL** writes them into vd one word per clock. vd may overlap a source
  group, so writing mask bits during RUN could clobber a source element before
  it is read. Reductions write `vd[0]` in FINAL.

Element `i` is *active* unless it is masked off by `v0` (when `vm = 0`), or it
is below the offset of a `vslideup`.

**The element ALU.** It handles the arithmetic and logic at SEW (operands are
sign- or zero-extended from their lane, so one 32-bit ALU serves all three
widths), compares, mask logic and reductions. A signed 33 × 33 multiplier
gives `vmul` (low half) and `vmulh*` (high half at SEW). The multiply-adds are
`vmacc` (vd + vs1·vs2) and `vmadd` (vs1·vd + vs2), plus their subtracting
forms.

**Decode and legality** are in the unit: `is_vec`, `is_cfg` and `illegal`
come out to the core's ID/EX. An encoding is illegal when:

- it is unsupported;
- `vtype.vill` is set and the instruction needs vtype;
- a register group is misaligned for its LMUL or EMUL (`v2` at LMUL=4 is
  illegal);
- a masked op writes v0;
- a memory op's EMUL = EEW/SEW·LMUL falls outside 1/8 … 8;
- `mstatus.VS` is Off.

### vsetvl in EX

`vsetvli rd, rs1, vtypei` sets `vtype` and returns
`vl = min(AVL, VLMAX)`, where `VLMAX = VLEN/SEW · LMUL`. AVL is:

- `rs1` (a register), or
- the immediate (`vsetivli`), or
- "as many as possible" when rs1 = x0 and rd ≠ x0, or
- "keep vl" when rs1 = rd = x0.

A vtype is legal when SEW ≤ 32, LMUL is not the reserved code, no reserved
bits are set, and fractional LMUL keeps SEW/LMUL ≤ ELEN. For example, e16 with
mf4 is illegal at ELEN=32, and e8 with mf4 is legal. An illegal vtype sets
`vill` and makes vl 0.

The core does `vsetvl*` in **one EX cycle**. It is a scalar result written to
rd, and the core forwards it like an ALU result. The unit's FSM is not
involved. vtype and vl commit when the instruction leaves EX.

## In the pipeline

**Holding EX.** A vector instruction other than vsetvl stays in EX until the
unit says `done`. This is the same `ex_hold` that Step 42 built for a D-TLB
walk:

```verilog
wire v_wait  = idex_valid & idex_vec & ~v_is_cfg & ~v_done &
               (v_busy | (~exception & ~irq_pending));
assign ex_hold = ex_dwalk | v_wait;
```

The unit starts only once the older instruction in MEM has finished with the
D-port (`v_start = v_wait & ~v_busy & ~m_port & ~ptw_busy & ~halt`). EX's
operands are forwarded as for any instruction, so `rs1` (the base address, a
scalar) and `rs2` (a stride, or vtype for `vsetvl`) are correct when it
starts. Scalar results (`vmv.x.s`, `vcpop.m`, `vfirst.m`) go to rd through the
normal writeback path.

**Memory.** Each element access goes through the core's D-port with
`d_addr = v_pa`. Its virtual address goes through the **D-TLB**, which now
looks up `dtlb_va = v_mem_active ? v_mem_va : ex_va`. A TLB miss starts the
**page-table walker**, exactly as a scalar miss does. Permission checks are the
scalar ones (R for loads, W for stores, U/SUM/MXR), so vector code runs
translated in S- and U-mode. Port priority is walker > vector > MEM. Because
the vector unit only starts once MEM is idle, they never actually compete.
With the D-cache, an element that misses waits for the refill like any load:
the unit only advances on `mem_done`.

**Precise traps mid-vector.** When element *i*'s translation faults, the unit
stops. It writes `vstart = i`, `mtval/stval` = that element's VA, and cause 13
(load) or 15 (store), and the core takes the trap with `mepc` = the vector
instruction. Elements below *i* are complete and the rest untouched. Once the
handler has mapped the page, `mret` re-executes the same instruction, and the
unit starts at `vstart` instead of 0. Every instruction that completes resets
vstart to 0. A **fault-only-first** load (`vle32ff.v`) that faults at
*i* > 0 does not trap: it sets `vl = i` and completes. A fault at element 0
traps as usual. This is what lets `strlen` read past the end of a string
without faulting.

**Interrupts** are not taken in the middle of a vector instruction. The
running instruction finishes first:
`irq_take = … & ~(idex_vec & (v_busy | v_done))`. An interrupt that arrives
before a vector instruction starts is taken in its place (`v_wait` requires
`~irq_pending` to start). The cost is interrupt latency: up to one vector
instruction, which is VLMAX elements, 256 clocks at VLEN=256 and LMUL=8.
Resumable vector interrupts would also be legal, using the same `vstart`
mechanism, but nothing here needs them.

**mstatus.VS.** `mstatus[10:9]` is the vector state: Off / Initial / Clean /
Dirty. It works like FS for the FPU. While it is **Off**, every vector
instruction and vector CSR access is illegal. That lets an OS start a process
with vectors off and allocate vector state lazily on the first trap. Anything
that changes vector state moves it to **Dirty**: a vector instruction, a
`vsetvl`, or a vector CSR write. `mstatus.SD` (bit 31) reads 1 while VS is
Dirty, so a context switch can tell whether it must save the 32 × VLEN-bit
register file. In `csr_s`, `HAS_V=0` hard-wires VS to 0, so software can
detect a core without V the standard way. `vl`, `vtype` and `vlenb` live in
the read-only CSR space (`0xC2x`). As the privileged spec requires, the core
now treats any *write* there as an illegal instruction, for every read-only
CSR: `csrrw`, or `csrrs`/`csrrc` with a nonzero source. They change only
through `vsetvl*`. The multi-cycle S-mode core
instantiates it that way.

## Verification

**1. Random differential testing against an RVV model** (`tools/vtest/`).
`vgen.py` generates a random but legal instruction stream and runs the same
stream through a Python model of the RVV semantics. A stream does three
things:

1. It loads all 32 registers with random data.
2. It runs N random operations: vsetvli with random SEW, LMUL and AVL (0, 1,
   VLMAX, more than VLMAX, random); every arithmetic, multiply, compare,
   reduction, mask, slide and move form, masked and unmasked; and every kind
   of load and store at random EEW, over random index tables.
3. It stores every scalar result and all 32 registers.

`run.py` assembles the stream, runs it on the RTL and compares 16 KiB of
memory word for word. `--bisect SEED` finds the shortest failing prefix,
which names the first wrong instruction.

| run | seeds × ops | result |
|---|---|---|
| VLEN=128, `soc_pipe_u` | 1,000 × 120 + 200 × 60 | all pass |
| VLEN=64 | 300 × 100 | all pass |
| VLEN=256 | 300 × 100 | all pass |
| VLEN=128, `soc_pipe_c` (caches, latency-7 memory, 16-line D-cache) | 300 × 120 | all pass |
| VLEN=256, `soc_pipe_c` | 100 × 120 | all pass |

The first run found one bug. `vslideup.vi` and `vslidedown.vi` took their
offset from `x[rs1]` instead of the 5-bit immediate. To check that the checker
itself has teeth, I broke one model operation (`vredxor` as OR): 28 of 100
seeds then failed.

**2. Faults under Sv32** (`sw/vec_vm.S`, expected output
`tb/vec_vm_expected.txt`). M-mode builds a page table with one 4 KiB hole and
runs S-mode code translated:

```
trap 0000000d 00003000 00000002     vle32 faults at element 2: cause, VA, vstart
vle32 v1[0] v1[3] vstart: a0a0a0a0 a3a3a3a3 00000000      ... resumed: all 4 loaded
trap 0000000f 00003000 00000002     vse32: store fault at element 2, resumed
vle32ff vl v4[0]: 00000002 a0a0a0a1                       fault-only-first: vl trimmed to 2
trap 0000000d 00003000 00000000     vle32ff whose element 0 faults: traps
trap 0000000d 00003000 00000002     vlse32 (stride 8): fault at element 2
trap 0000000d 00003008 00000002     vluxei32: fault at element 2, at its own VA
trap 80000007 00000000 00000000     timer interrupt due mid-vid.v: taken after it
irq: vl sum: 00000020 00005160                            ... results intact
```

**3. The OpenZynq self-test** (`sw/oz/selftest.c`) runs on every generated
configuration with V. It checks that a vector instruction is illegal while VS
is Off; a 37-element strip-mined `vle32 / vmadd / vse32 / vredsum` against
the scalar result; that writing the read-only `vl` traps; and `vlenb = VLEN/8`,
VS = Dirty, SD = 1 afterwards. A
configuration without V checks that VS reads 0 and `vsetvli` traps.

**4. Regressions.** riscv-tests on all 12 core configurations. `make pipe-u`,
`pipe-u-sv`, `cache`, and `rvgen-all` (all 9 presets) still pass.

`make vec` runs 1–2 and the benchmark.

## Benchmark

`sw/vec_bench.c` contains the same four kernels written in scalar C (built
with `-fno-tree-vectorize`) and with RVV intrinsics. They run on `soc_pipe_u`
at VLEN=128, are timed with `mtime` (one tick per clock), and every vector
result is checked against the scalar one:

| kernel | scalar | vector | speedup |
|---|---:|---:|---:|
| `vadd`  c = a + b, 256 × i32 | 1,802 | 1,220 | 1.47× |
| `saxpy` y = 3x + y, 256 × i32 | 2,313 | 1,212 | 1.90× |
| `dot`   Σ a·b, 256 × i32 | 1,548 | 1,228 | 1.26× |
| `copy`  1 KiB memcpy (e8, LMUL=8) | 5,128 | 2,165 | 2.36× |

Those numbers follow directly from the design. A strip-mined vector loop at
LMUL=8 does 32 elements per pass with about 8 instructions, so its loop
overhead is nearly free. Every element still costs one clock in each vector
instruction: `vadd` is 2 loads + 1 add + 1 store, 4 clocks per element, about
1,024 for 256 elements. The scalar loop costs 5–9 clocks per element. The
vector unit wins by not fetching, decoding and branching per element. It does
**not** win by doing several elements per clock, which is what a real vector
machine is for.

The next steps for performance would each multiply throughput, and none needs
an architectural change:

- **Lanes.** Do `VLEN/32` elements of SEW=32, or 4× as many bytes, per clock,
  with the VRF banked by word.
- **Word-wide unit-stride memory.** One D-port access per word, not per
  element. That alone would make `copy` at e8 4× faster.
- **Chaining.** Let the next vector instruction start on element 0 while the
  current one is still running.

## Toolchain notes

- GCC 13.2 compiles RVV intrinsics for `-march=rv32ima_zicsr_zve32x`. GCC 13
  does not auto-vectorize RVV by default, so plain C stays scalar.
- GCC 13.2 rejects the **reduction** intrinsics (`__riscv_vredsum_vs_*`) when
  ELEN = 32 ("invalid argument to built-in function"), for Zve32x and Zve32f.
  It accepts them for Zve64x and V. The benchmark and the self-test therefore
  do their reductions in a few lines of assembly.
- On RV32, `int32_t` is `long`. Pointers passed to the intrinsics must be
  `int32_t *`, not `int *`.

## Menuconfig

`Core → ISA extensions → V: vector unit` (pipeline only, default **n**) and
`VLEN` (64 / 128 / 256, default 128). rvgen adds `_zve32x` to the firmware's
`-march`, passes `V_EXT` and `VLEN` through `oz_rv_soc` to `cpu_pipe_u`, adds
`rtl/vec_unit.v` to the project, and sets `FEATURES` bit 20. A new preset,
`configs/oz_vec_defconfig`, is `oz_full` with V and without Zbc. V is not in
`oz_full`: see the cost below.

## Cost

`vec_unit` synthesized on its own, Yosys 0.68 `synth_xilinx -abc9 -arch xc7`.
LUTs are logic LUTs; the VRF is RAM64M LUT RAM, 4 LUTs each:

| VLEN | VRF | logic LUTs | LUT-RAM LUTs | FFs | DSP48 | CARRY4 |
|---:|---:|---:|---:|---:|---:|---:|
| 64  | 256 B  | 3,424 | 220 | 443 | 7 | 203 |
| 128 | 512 B  | 3,822 | 440 | 573 | 7 | 209 |
| 256 | 1 KiB  | 4,538 | 880 | 831 | 7 | 209 |

About 4,300 LUTs at VLEN=128, roughly 40 % of the rest of the full core
(`oz_full` is 11,031). It goes into:

- operand extraction and lane insertion at three element widths (`getz`/`put`);
- the per-element address arithmetic (unit/strided/indexed);
- 32-bit element counters and comparisons (`idx`, `vl`, `vstart`, slide
  offsets);
- the mask-result register (VLEN bits) that FINAL writes back;
- the 33 × 33 multiplier, which takes the 7 DSPs.

The VRF is replicated once per read port (vs2, vs1, old vd, v0 and the
`vmv<n>r` source). LUT RAM is cheap per bit, so five copies of 32 × VLEN
bits still cost only 440 LUTs at VLEN=128. The element counters are wider than
they need to be: VLMAX ≤ VLEN, so 9 bits would do. Narrowing them is the
first saving to make.

The whole SoC with V (`oz_vec`) is about 14,760 LUTs, 84 % of the
xc7z010: an estimate, since ABC's `&mfs` pass did not finish within
1.5 hours on the flattened design (docs/45). The first synthesis run also
found a real problem, a combinational loop.

### A loop that only exists in LUT RAM

That first synthesis reported a combinational loop (ABC9: "Found an SCC").
Simulation could not show it, and `check` on the RTL found none. The cause was
the VRF write address. In the first version, `w_addr` was assigned inside the
"element is active" branch of the write logic, so it went `c_addr` normally
and the `vmv<n>r` destination for that one instruction class. Activity depends
on the mask bit `v0[i]`, which is a VRF read. In RTL that is harmless: memory
writes on the clock edge. But a Xilinx LUT-RAM primitive (RAM64M) uses one
address input, `ADDRD`, both as the write address and as the address of its
fourth read output. The mapped netlist therefore had a real path: VRF read
(v0) → `active` → `w_addr` → `ADDRD` → VRF read. `scc -specify` after
`synth_xilinx -run :map_ffs` names the signals on such a loop. The fix is to
compute `w_addr` from the state alone and let `we` alone decide whether to
write:

```verilog
wire [AW-1:0] w_addr = (cls == C_MVNR && state == S_RUN) ? ewa(vd, idx, 2'd2) : c_addr;
```

The lesson for any LUT-RAM register file: keep the write address
independent of anything read from the same memory in that cycle.

## Files

| file | |
|---|---|
| `rtl/vec_unit.v` | the vector unit (new) |
| `rtl/cpu_pipe_u.v` | `V_EXT`/`VLEN`, decode, `ex_hold`, D-port and D-TLB sharing, vector traps, CSR routing |
| `rtl/csr_s.v` | `mstatus.VS`, `SD`, `HAS_V` |
| `rtl/soc_pipe_u.v`, `rtl/soc_pipe_c.v`, `rtl/oz/oz_rv_soc.v` | `VLEN` (and `V_EXT`) parameters |
| `tools/vtest/vgen.py`, `run.py`, `link.ld`, `tb/vec_diff_tb.v` | random differential test |
| `sw/vec_vm.S`, `tb/vec_vm_expected.txt` | faults / vstart / fault-only-first / interrupts under Sv32 |
| `sw/vec_bench.c` | scalar vs vector benchmark |
| `Kconfig`, `tools/rvgen/rvgen.py`, `sw/oz/selftest.c` | the option, `-march`, self-test |
