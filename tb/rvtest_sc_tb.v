// =====================================================================
// rvtest_sc_tb.v  -  riscv-tests harness for the byte-addressed bus cores
// ---------------------------------------------------------------------
// Covers the two cores that keep their instruction memory inside the core
// and drive a byte-addressed data bus (address + funct3 + one write
// enable). Chosen at compile time by tools/rvtests:
//
//   (default)         cpu_core       single-cycle RV32IMA + Zicsr
//   -DRVT_CORE_PIPE   cpu_pipe_trap  5-stage pipeline, RV32IM + Zicsr
//
// The pipelined core is the interesting one for this suite: every
// riscv-tests instruction file ends with a block of *_BYPASS cases that
// re-run each operation with 0, 1 and 2 nops between producer and
// consumer, which is exactly the forwarding matrix a 5-stage pipeline
// has to get right.
//
// As in the multi-cycle harness there is no SYSCON device: a store into
// the SYSCON window is the verdict, decoded by rvtest_harness.vh.
// =====================================================================
`timescale 1ns/1ps
`default_nettype none

module rvtest_sc_tb;
    localparam ROM_WORDS = 8192;         // 32 KB instruction ROM
    localparam RAM_BYTES = 65536;        // 64 KB data RAM

    reg clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    wire [31:0] daddr, dwdata, drdata;
    wire        dwe;
    wire [2:0]  dfunct3;
    wire [31:0] rvt_pc, rvt_instr;

`ifdef RVT_CORE_PIPE
    cpu_pipe_trap #(.IMEM_WORDS(ROM_WORDS)) u_core (
`else
    cpu_core #(.IMEM_WORDS(ROM_WORDS)) u_core (
`endif
        .clk(clk), .rst(rst), .timer_irq(1'b0),
        .pc_out(rvt_pc), .instr_out(rvt_instr),
        .dmem_addr(daddr), .dmem_wdata(dwdata), .dmem_we(dwe),
        .dmem_funct3(dfunct3), .dmem_rdata(drdata)
    );

    wire sel_ram = (daddr[31:28] == 4'h0);
    dmem #(.BYTES(RAM_BYTES)) u_ram (
        .clk(clk), .we(dwe && sel_ram), .addr(daddr), .wdata(dwdata),
        .funct3(dfunct3), .rdata(drdata)
    );

    // ---- what rvtest_harness.vh needs ---------------------------------
    wire        rvt_wr    = dwe;
    wire [31:0] rvt_waddr = daddr;
    wire [31:0] rvt_wdata = dwdata;

    // The ROM is a word array (word-per-line image); this RAM is a BYTE
    // array, so it takes the byte-per-line image with its @<byte-address>
    // record instead.
    task rvt_load;
        input [1023:0] romf;
        input [1023:0] ramf;
        input          has_ram;
        begin
            $readmemh(romf, u_core.u_imem.mem);
            if (has_ram) $readmemh(ramf, u_ram.mem);
        end
    endtask

    `include "tb/rvtest_harness.vh"
endmodule

`default_nettype wire
