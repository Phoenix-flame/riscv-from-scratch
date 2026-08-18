// =====================================================================
// rvtest_mc_tb.v  -  riscv-tests harness for the multi-cycle core family
// ---------------------------------------------------------------------
// Covers the three cores that share the BRAM-style bus (word address +
// byte-write mask + registered read). Which one is instantiated is
// chosen at compile time by tools/rvtests:
//
//   (default)      cpu_mc     RV32IM  + Zicsr
//   -DRVT_CORE_C   cpu_mc_c   RV32IMC + Zicsr
//   -DRVT_CORE_F   cpu_mc_f   RV32IMF + Zicsr
//
// The system around the core is deliberately the minimum the suite
// needs: a 32 KB instruction ROM at 0x0, a 64 KB data RAM at 0x0 (the
// tests' data window starts at 0x8000, see tests/riscv-tests/env/link.ld)
// and nothing else. There is no SYSCON device -- a store to the SYSCON
// address IS the verdict, and rvtest_harness.vh catches it on the bus.
// =====================================================================
`timescale 1ns/1ps
`default_nettype none

module rvtest_mc_tb;
    localparam ROM_WORDS = 8192;         // 32 KB instruction ROM
    localparam RAM_WORDS = 16384;        // 64 KB data RAM

    reg clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    wire [31:0] iaddr, irdata;
    wire [31:0] daddr, dwdata, drdata;
    wire [3:0]  dwe;
    wire [31:0] rvt_pc;

`ifdef RVT_CORE_C
    cpu_mc_c u_core (
`elsif RVT_CORE_F
    cpu_mc_f u_core (
`else
    cpu_mc u_core (
`endif
        .clk(clk), .rst(rst), .timer_irq(1'b0), .ext_irq(1'b0), .halt(1'b0),
        .imem_addr(iaddr), .imem_rdata(irdata),
        .dmem_addr(daddr), .dmem_we(dwe), .dmem_re(),
        .dmem_wdata(dwdata), .dmem_rdata(drdata),
        .pc_out(rvt_pc)
    );

    bram_rom #(.WORDS(ROM_WORDS)) u_rom (
        .clk(clk), .addr_word(iaddr[$clog2(ROM_WORDS)+1:2]), .rdata(irdata)
    );

    wire sel_ram = (daddr[31:28] == 4'h0);
    bram_ram #(.WORDS(RAM_WORDS)) u_ram (
        .clk(clk), .addr_word(daddr[$clog2(RAM_WORDS)+1:2]),
        .we(sel_ram ? dwe : 4'b0000), .wdata(dwdata), .rdata(drdata)
    );

    // ---- what rvtest_harness.vh needs ---------------------------------
    wire [31:0] rvt_instr  = irdata;
    wire        rvt_wr     = |dwe;
    wire [31:0] rvt_waddr  = daddr;
    wire [31:0] rvt_wdata  = dwdata;

    // Both images are word-per-line ($readmemh into a 32-bit array); the
    // RAM image carries an @<word-index> record for its 0x8000 base.
    task rvt_load;
        input [1023:0] romf;
        input [1023:0] ramf;
        input          has_ram;
        begin
            $readmemh(romf, u_rom.mem);
            if (has_ram) $readmemh(ramf, u_ram.mem);
        end
    endtask

    `include "tb/rvtest_harness.vh"
endmodule

`default_nettype wire
