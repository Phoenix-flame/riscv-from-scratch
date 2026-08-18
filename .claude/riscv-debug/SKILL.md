---
name: riscv-debug
description: >
  Use this skill whenever the user has a failing or misbehaving simulation in the
  RISC-V CPU tutorial project and needs to diagnose it. Triggers on: a testbench
  printing FAIL or wrong values, a simulation that hangs (times out or runs
  forever), wrong claim order from the PLIC, wrong writeback values, a trap that
  fires at the wrong time or not at all, a branch that mispredicts when it
  shouldn't, an RVC straddling fetch that produces the wrong instruction, iverilog
  compile errors, or any request to "debug", "trace", "diagnose", or "figure out
  why X doesn't work" in the context of this project's Verilog simulation.
---

# RISC-V Simulation Debug Skill

Fast diagnostic process for the iverilog/vvp simulation stack in this project.
The toolchain is iverilog 12.0; no gdb; no waveform viewer in CI. All debugging
is done by inserting `$display` statements into a scratch testbench.

## Step 0: read the compile error first

Before looking at runtime behaviour, make sure iverilog compiles cleanly:
```bash
iverilog -g2012 -o build/foo_tb.vvp $(RTL_LIST) tb/foo_tb.v 2>&1 | head -30
```

Common compile errors and fixes:

| Error | Fix |
|---|---|
| `unknown module type: bram_ram` | Add `rtl/bram_ram.v` to RTL list |
| `unknown module type: csr` | Add `rtl/csr.v` |
| `port 'dmem_re' not found` | New port on cpu_mc; add `.dmem_re()` (unconnected) to old SoC instances |
| `syntax error, unexpected reg` | Missing `` `default_nettype none `` before a `wire` used as implicit net |
| `implicit definition of wire` | Declare the wire explicitly |
| multiple driver warnings | A `wire` driven by two always/assign blocks; change to `reg` |

## Step 1: classify the failure mode

**Simulation hangs / timeout**
The firmware is stuck in a `while` loop. Most common causes:
- BSS not zeroed — counter starts garbage, `while (nclaim < 3)` condition is
  wrong from the start.
- Testbench `wait_for` loop has no guard and spins forever.
- An interrupt never fires: MEIE/MIE not set, `mtvec` wrong, peripheral not
  wired to `ext_irq`.
- The peripheral select never asserts: peripheral address decode wrong, or
  `dvalid` gate blocks legitimate accesses.

**Wrong values printed / assertions fail**
The firmware ran but computed the wrong thing. Most common causes:
- Read-side-effect fired at wrong time (see PLIC section below).
- Load returned wrong value: sampled in EXEC not MEM.
- A peripheral's `rdata` is not connected to the SoC `drdata` mux.
- BSS variable not zeroed.

**Correct values but wrong order (e.g. PLIC claim order)**
Priority/arbitration bug, or the claim side-effect fired on a non-load cycle.

---

## Step 2: add a targeted diagnostic testbench

Never modify the real testbench. Copy it to `/tmp/diag.v` and add `$display`
lines, or write a minimal standalone one.

### Minimal per-cycle trace template

```verilog
`timescale 1ns/1ps
`default_nettype none
module diag;
    reg clk=0, rst=1; always #5 clk=~clk;
    // ... instantiate DUT ...

    // --- trace: print every cycle while 'trace' is set ---
    reg trace=0;
    always @(posedge clk) if (trace)
        $display("[%0t] state=%0d pc=%03h daddr=%05h dwe=%b rdata=%0d",
            $time, dut.u_core.state, dut.u_core.pc[11:0],
            dut.daddr[15:0], dut.dwe, dut.drdata);

    initial begin
        repeat(3) @(posedge clk); #1; rst=0;
        // wait for the region of interest, then enable trace:
        repeat(50) @(posedge clk); trace=1;
        repeat(30) @(posedge clk); trace=0;
        $finish;
    end
endmodule
`default_nettype wire
```

### Watching a specific signal transition

```verilog
always @(posedge clk) if (!rst)
    if (dut.sel_plic & ~dut.wr_any & (dut.daddr[15:0]==16'h3004))
        $display("[%0t] PLIC CLAIM read: stb=%b cid=%0d creg=%0d rdata=%0d",
            $time, dut.u_plic.claim_stb, dut.u_plic.claim_id,
            dut.u_plic.claimed_reg, dut.plic_rdata);
```

### Watching register writes

```verilog
always @(posedge clk) if (dut.u_core.rf_we && !rst)
    $display("[%0t] rf_write: x%0d <- %0d (0x%h)",
        $time, dut.u_core.rd_addr, dut.u_core.wb_data, dut.u_core.wb_data);
```

---

## Step 3: PLIC-specific debugging

The most common PLIC bug is a spurious claim triggered by a non-load instruction
whose ALU result coincidentally equals the claim address (`0x1002_3004`).

**Symptom:** claim sequence is `3, 4, 4, 2` instead of `3, 4, 2` — a source ID
is repeated, and `nclaim` ends at 1 with the wrong value in `claimed[0]`.

**Diagnostic:**
```verilog
always @(posedge clk) if (!rst && dut.sel_plic && (dut.daddr[15:0]==16'h3004))
    $display("[%0t] st=%0d pc=%03h we=%b dre=%b stb=%b cid=%0d creg=%0d",
        $time, dut.u_core.state, dut.u_core.pc[11:0],
        dut.dwe!=0, dut.u_core.dmem_re,
        dut.u_plic.claim_stb, dut.u_plic.claim_id, dut.u_plic.claimed_reg);
```

If `dre=0` (dmem_re is low) but `stb=1` fired — the peripheral select is not
gated on the read strobe. Fix: add `wire dvalid = dre | wr_any` and qualify
`sel_io = dvalid & ...`.

**Symptom:** `meip` never rises even though the peripheral is asserting.

Check in order:
1. `PRIO(i)` > 0 for the source? (Priority 0 = never interrupt)
2. `ENABLE` bit set for the source?
3. `THRESH` < `PRIO(i)`?
4. Is the source connected to the right `plic_src[i]` bit in the SoC?
5. Does `plic.meip` actually connect to `cpu_mc.ext_irq`?
6. Is `MEIE` (mie bit 11) set in firmware?
7. Is global `MIE` (mstatus bit 3) set in firmware?

---

## Step 4: interrupt / trap debugging

**Symptom:** trap fires at wrong PC (mepc points to wrong instruction)

The multi-cycle core has `trap_take = take_trap & in_exec` to prevent trapping
during S_MEM. If a trap fires during S_MEM, mepc captures the load instruction's
PC twice (the load is re-fetched and re-executes as a trap handler entry). Check:
```verilog
always @(posedge clk) if (dut.u_core.take_trap && !rst)
    $display("[%0t] TRAP: state=%0d pc=%0h cause=%0d",
        $time, dut.u_core.state, dut.u_core.pc, dut.u_csr.mcause);
```

**Symptom:** ISR runs but PLIC drains 0 claims

The pending bits may have cleared before the claim read. Check:
- `plic.pend[k]` at the time of the claim read.
- Whether `complete` (CLAIM write) was issued before all pending sources were
  claimed — a complete while others are pending can confuse the arbiter if the
  firmware loops exits too early.

**Symptom:** mret returns to wrong address (loops or jumps to 0)

```verilog
always @(posedge clk) if (dut.u_core.is_mret && dut.u_core.in_exec)
    $display("MRET: mepc=%0h -> next_pc=%0h", dut.u_csr.mepc, dut.u_core.next_pc);
```

For RVC: mepc must carry bit 1 so the return lands at the halfword-aligned address.
If mepc is being masked to word alignment, the return skips a halfword.

---

## Step 5: RVC / fetch debugging

**Symptom:** wrong instruction executed after a straddle

Check which word the core is reading. With `cpu_mc_c`:
- `straddle_q==1` means we're waiting for word N+1
- `lo_half` holds the low 16 bits of the straddling instruction
- `instr` should be `{imem_rdata[15:0], lo_half}` after the second read

```verilog
always @(posedge clk) if (!rst && dut.u_core.state==3'd1)
    $display("[%0t] EXEC: pc=%h is_c=%b need_hi=%b straddle_q=%b instr=%h",
        $time, dut.u_core.pc, dut.u_core.is_c,
        dut.u_core.need_hi, dut.u_core.straddle_q, dut.u_core.instr);
```

**Symptom:** c.jal or c.jalr writes wrong link address

Link for compressed jumps is `pc + 2`. If the writeback shows `pc + 4`, the
`pc_nexti` calculation in `cpu_mc_c` is using `is_c` from the wrong instruction
(e.g., the old IF-stage `is_c` rather than the executing one).

---

## Step 6: branch predictor debugging

**Symptom:** `perf_mispred` equals `perf_taken` (no predictions helping)

The BTB never gets a hit. Check:
- Is `upd_en` firing? (Should be every `ex_is_ctrl` cycle)
- Is the BTB index correct? (`IDX_BITS` determines table size; with 64 entries
  and a tight loop, verify the loop's PC maps to a stable index)

**Symptom:** predictor shows same cycle count as not-taken baseline

The perf counters are free-running. Make sure you latch them at `bp_done`, not
at the end of the simulation — by then the halt spin loop has been counting.
```verilog
always @(posedge clk) if (!bp_done && bp_word_done)
    begin bp_done<=1; bp_cyc_s<=bp_cyc; bp_mis_s<=bp_mis; end
```

---

## Quick diagnostic scripts

**Check RAM contents at fixed addresses after sim:**
```bash
# In the testbench, at $finish, dump key addresses:
$display("RAM[0x800]=%0h RAM[0x804]=%0h RAM[0x808]=%0h",
    dut.u_ram.mem['h800>>2], dut.u_ram.mem['h804>>2], dut.u_ram.mem['h808>>2]);
```

**Print all non-zero RAM words (for debugging what firmware wrote):**
```verilog
integer dbg_i;
initial begin
    #(SIM_CYCLES * 10);
    for (dbg_i = 0; dbg_i < 512; dbg_i = dbg_i+1)
        if (dut.u_ram.mem[dbg_i] !== 0)
            $display("  ram[0x%03h] = 0x%08h", dbg_i*4, dut.u_ram.mem[dbg_i]);
end
```

**Verify nm symbols before debugging at the Verilog level:**
```bash
riscv64-unknown-elf-nm build/prog.elf | sort
# Check: trap_handler is at 4-byte-aligned address
# Check: main is where you expect
# Check: claimed / nclaim are in expected BSS range
```
