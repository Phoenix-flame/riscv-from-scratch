---
name: riscv-rtl-step
description: >
  Use this skill whenever the user asks to add, extend, or modify a hardware block
  in the RISC-V CPU tutorial project — anything involving writing or changing
  Verilog (.v) files, creating a new testbench, wiring a new peripheral into a SoC,
  adding a Makefile target, or implementing a new CPU feature (pipeline stage,
  branch predictor, PLIC, C extension, MMU, etc.). Triggers on phrases like
  "add a ...", "implement ...", "wire up ...", "build a ... module", "new step",
  or any description of a hardware feature followed by a request to build it.
  Also triggers when the user pastes failing iverilog/vvp output and wants the RTL fixed.
---

# RISC-V RTL Step Skill

This project is a from-scratch RV32IMA CPU built as a verified step-by-step
tutorial. The toolchain is `iverilog` 12.0 + `riscv64-unknown-elf-gcc` 13.2.0
(no newlib, no gdb). Work lives in `~/riscv-cpu-tutorial/`; outputs go to
`/mnt/user-data/outputs/riscv-cpu-tutorial/`.

## Project conventions

**Memory map**
```
0x0000_0000  RAM (bram_ram)
0x1000_0000  UART   (daddr[17:16]==00)
0x1001_0000  CLINT  (daddr[17:16]==01)
0x1002_0000  PLIC   (daddr[17:16]==10)
0x2000_0000  SYSCON (write -> halt)
```

**Bus interface** (`cpu_mc` and all SoCs)
- `daddr` / `dwdata` / `dwe[3:0]` (byte-enables) / `drdata`
- `dmem_re` — a genuine-load read strobe; ALWAYS gate peripheral read-side-effects
  on this, never on address alone. Any peripheral with read-side-effects
  (e.g. PLIC claim) must qualify: `sel = (daddr_match) & (dmem_re | wr_any)`.
  This is the lesson of Step 33: `dmem_addr = alu_result` fires on EVERY
  instruction, so an ALU op can coincidentally equal a peripheral address.

**cpu_mc FSM states**
```
S_FETCH=0  S_EXEC=1  S_MEM=2  S_HALT=3
```
- `instr = imem_rdata` is valid in EXEC and MEM (PC held).
- `dmem_addr = alu_result` is combinational — driven every cycle.
- Stores assert `dmem_we` only in S_EXEC; loads sample `dmem_rdata` in S_MEM.
- `dmem_re = mem_read & (in_exec | in_mem)`.
- Trap gate: `wire trap_take = take_trap & in_exec` — never trap during S_MEM.

**Register-file write-back select** (`wb_sel`)
```
WB_ALU=2'b00  WB_MEM=2'b01  WB_PC4=2'b10  WB_IMM=2'b11
```

**RVC cpu_mc_c additions**
- Halfword-aligned PC; `is_c = raw16[1:0] != 2'b11`.
- Straddle: 32-bit instr at pc[1]==1 spans two words. Discovery EXEC commits
  nothing; presents word N+1 to ROM in same cycle (one-cycle straddle penalty).
- Link for c.jal/c.jalr is `pc + 2`, not `pc + 4`.
- `mepc` keeps bit 1 (IALIGN=16); `jalr` clears only bit 0.

**PLIC register map** (byte offsets within PLIC window)
```
0x0000 + 4*i  priority[i]   RW
0x1000        pending bitmap RO
0x2000        enable bitmap  RW
0x3000        threshold      RW
0x3004        claim/complete RW (read=claim with side-effect, write=complete)
```

**CLINT** at 0x1001_0000: `mtimecmp` at +0x4000, `mtime` at +0xBFF8.

**Firmware build flags**
```
base:      -march=rv32i    -mabi=ilp32 -nostdlib -nostartfiles -ffreestanding -O1
with-M:    -march=rv32im
with-Zicsr:-march=rv32i_zicsr  (or rv32im_zicsr, rv32imc_zicsr)
linker:    -T sw/link.ld sw/crt0.s <src.c> -lgcc
```
`crt0.s` sets `sp = 0x1000`, calls `main`, stores `a0` at address 0, then halts.
BSS is NOT zeroed by crt0 — initialise in `main` explicitly.

**Hex generation**
```
riscv64-unknown-elf-objcopy -O binary foo.elf foo.bin
python3 sw/bin2hex.py foo.bin > sw/foo.hex
```
`bin2hex.py` pads to 4-byte alignment, emits one 32-bit little-endian word per line.

**bram_ram** is word-addressed: `mem[byte_addr >> 2]`. Read from testbench as:
```verilog
function [31:0] rd; input [31:0] a; rd = dut.u_ram.mem[a>>2]; endfunction
```

**bram_rom** is word-addressed: `addr_word = iaddr[clog2(WORDS)+1 : 2]`.

---

## Step implementation workflow

### 1. Understand the interface before writing

Before writing any RTL:
- Read the module that will instantiate the new block (SoC or CPU core).
- Check which signals are already on the data bus vs. what you need to add.
- For peripherals with read-side-effects: design the strobe logic first.
- For CPU changes: identify which FSM states are affected and what is or isn't committed in each.

### 2. Write the RTL module

Follow the project's Verilog style:
```verilog
// =====================================================================
// module_name.v  -  one-line purpose
// ---------------------------------------------------------------------
// 3-5 line description of the design: what problem it solves, the key
// mechanism, any non-obvious design choices.
// =====================================================================
`default_nettype none

module module_name #(
    parameter FOO = 4
) (
    input  wire clk,
    input  wire rst,
    ...
);
    // design here
endmodule

`default_nettype wire
```

Key RTL discipline:
- Use `wire` for combinational, `reg` for clocked state.
- Always define reset behaviour in every `always @(posedge clk)`.
- Never read `dmem_rdata` in S_EXEC — it's registered (valid in S_MEM).
- Gate peripheral selects on `dvalid = dmem_re | wr_any`, not bare address.
- For read-side-effects (PLIC claim, FIFO pop): use an edge-detected strobe
  (`claim_stb = claim_rd & ~claim_d`) and latch the result so it stays stable
  across the 2-cycle load (EXEC presents, MEM samples).

### 3. Wire into the SoC

Create or modify `rtl/soc_<name>.v`:
- Instantiate `cpu_mc` with `.dmem_re(dre)` connected.
- Decode `daddr[31:28]` for region, `daddr[17:16]` for peripheral within IO space.
- Gate all peripheral selects on `dvalid`.
- Multiplex `drdata` with priority (last assignment wins, or explicit mux).

### 4. Write the testbench

Pattern from `tb/plic_tb.v` / `tb/rvc_tb.v`:
```verilog
`timescale 1ns/1ps
`default_nettype none
module foo_tb;
    reg clk=0, rst=1; always #5 clk=~clk;
    // instantiate DUT
    // rd() function for RAM
    // wait_for() task with guard counter (max 500000 cycles)
    integer fails=0;
    initial begin
        repeat(3) @(posedge clk); #1; rst=0;
        // test phases
        if (fails==0) $display("FOO: ALL PASS");
        else          $display("FOO: %0d FAIL", fails);
        $finish;
    end
endmodule
`default_nettype wire
```

Guard every `while` loop against infinite spin:
```verilog
task wait_for; input [31:0] a; input [31:0] val; integer g; begin
    g=0; while (rd(a)!==val && g<500000) begin @(posedge clk); g=g+1; end
end endtask
```

### 5. Add the Makefile target

```makefile
RTL_FOO = rtl/control.v rtl/alu.v rtl/regfile.v rtl/immgen.v rtl/csr.v \
          rtl/cpu_mc.v rtl/bram_rom.v rtl/bram_ram.v rtl/foo.v rtl/soc_foo.v

sw/foo_demo.hex: sw/foo_demo.c sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32im_zicsr -mabi=ilp32 -nostdlib \
	  -nostartfiles -ffreestanding -O1 -T sw/link.ld sw/crt0.s \
	  sw/foo_demo.c -o $(B)/foo.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/foo.elf $(B)/foo.bin
	python3 sw/bin2hex.py $(B)/foo.bin > sw/foo_demo.hex

foo: sw/foo_demo.hex ## short description of what this tests
	$(IV) -o $(B)/foo_tb.vvp $(RTL_FOO) tb/foo_tb.v && $(VVP) $(B)/foo_tb.vvp
```

Note: if the target also shows `size` output from ELF files, put it AFTER the
simulation line, with a `|| echo "(hint)"` fallback (the hex may be pre-built
so the ELF won't exist in that case — see Step 34's rvc target for the pattern).

### 6. Verify

Always compile and run before declaring done:
```bash
iverilog -g2012 -o build/foo_tb.vvp $(RTL_FOO) tb/foo_tb.v
vvp build/foo_tb.vvp 2>/dev/null | grep -vE "readmem|RWX"
```

Compile errors to watch for:
- Missing `dmem_re` port on old SoCs that instantiate `cpu_mc` (leave unconnected: `.dmem_re()`)
- `$clog2` in port width expressions: requires `-g2012`
- `wire` driven by multiple `assign` or always blocks → use `reg` for mux outputs

### 7. Checkpoint: run the full regression before packaging

```bash
for t in cpu muldiv pipe pipe-sum bpred irq priv pipe-irq atomic clint \
          rtos-smoke freertos-fpga-run mmu-hw debug-selftest \
          uart-loopback uart-echo uart-irq plic rvc <new-target>; do
    make $t 2>/dev/null | grep -iE "PASS|FAIL|exit code|ALL TESTS" | tail -1
done
```

All existing targets must still pass — the new `dmem_re` port is backward-
compatible (other SoCs leave it unconnected), but changes to shared modules
(csr.v, control.v, alu.v, cpu_mc.v) need the full sweep.

### 8. Package

Stage in `/tmp`, never write directly to the output mount during `make`:
```bash
rm -rf /tmp/pkg && mkdir -p /tmp/pkg/riscv-cpu-tutorial
cp -r rtl tb sw docs constraints Makefile README.md .gitignore /tmp/pkg/riscv-cpu-tutorial/
cd /tmp/pkg/riscv-cpu-tutorial && rm -rf build
find . \( -name '*.vcd' -o -name '*.vvp' -o -name '*.elf' -o -name '*.bin' \) -delete
# verify from clean:
make <new-target> 2>/dev/null | grep -E "PASS|FAIL"
rm -rf build
cd /tmp/pkg && zip -qr riscv-cpu-tutorial.zip riscv-cpu-tutorial
cp riscv-cpu-tutorial.zip /mnt/user-data/outputs/
```

---

## Common gotchas

| Symptom | Likely cause | Fix |
|---|---|---|
| Peripheral claiming/reading before the load even executes | Missing `dmem_re` gate — ALU result coincidentally equals the address | Add `dvalid = dmem_re \| wr_any`, gate all peripheral selects |
| Double-claim / read-side-effect fires twice | Edge strobe `claim_stb` de-asserts and re-asserts within one load (e.g. address momentarily changes) | Also gate on `dvalid`, or widen the latch window |
| Load returns wrong value | `dmem_rdata` sampled in EXEC, not MEM | Move sampling to S_MEM |
| Interrupt during load's MEM cycle causes double-trap | `take_trap` not gated on `in_exec` | Use `trap_take = take_trap & in_exec` |
| Make target fails: "No such file" on ELF | `size` line runs before hex prerequisites build | Move size display after simulation, make it non-fatal |
| iverilog I/O error on output mount | Writing build artifacts to `/mnt/user-data/outputs/` | Always stage in `/tmp`, copy only the final zip |
| Stale hex satisfies Make but ELF missing | hex committed to tree but build/ is gitignored | See packaging note above for the `|| echo` fallback |
