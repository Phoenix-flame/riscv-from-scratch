// =====================================================================
// rvtest_pc_tb.v  -  riscv-tests harness: unified pipeline + caches
// ---------------------------------------------------------------------
// cpu_pipe_u behind a 512-byte I-cache and a 512-byte write-back D-cache
// (16 lines x 8 words each) on slow memory (latency 5). Small on purpose:
// the suite's code and data do not fit, so refills, dirty evictions and
// PTE reads through the D-cache all happen inside the tests. tools/rvtests
// runs it as `pipe_c` (body in M) and `pipe_c_vm` (-DRVTEST_VM: body in
// U with Sv32 on).
// =====================================================================
`timescale 1ns/1ps
`default_nettype none

module rvtest_pc_tb;
    localparam ROM_WORDS = 8192;         // 32 KB instruction memory
    localparam RAM_WORDS = 16384;        // 64 KB data memory
    localparam LW = 8, LWB = 32*8;

    reg clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    wire [31:0] iaddr, irdata, daddr, dwdata, drdata, ram_rdata;
    wire        ireq, iready, dreq, ram_ready;
    wire [3:0]  dwe;
    wire [31:0] rvt_pc;

    cpu_pipe_u u_core (
        .clk(clk), .rst(rst), .timer_irq(1'b0), .mtime(64'd0), .meip(1'b0), .seip(1'b0), .halt(1'b0),
        .i_addr(iaddr), .i_req(ireq), .i_rdata(irdata), .i_ready(iready),
        .d_addr(daddr), .d_req(dreq), .d_we(dwe), .d_wdata(dwdata),
        .d_rdata(drdata), .d_ready(sel_ram ? ram_ready : 1'b1),
        .pc_out(rvt_pc), .retire()
    );
    wire sel_ram = (daddr[31:28] == 4'h0);
    assign drdata = ram_rdata;

    wire im_req, im_done, dm_req, dm_we, dm_done;
    wire [31:0] im_addr, dm_addr;
    wire [LWB-1:0] im_rdata, dm_wdata, dm_rdata;

    icache #(.LINES(16), .LINE_WORDS(LW)) u_icache (
        .clk(clk), .rst(rst), .addr(iaddr), .req(ireq), .rdata(irdata), .ready(iready),
        .m_req(im_req), .m_addr(im_addr), .m_done(im_done), .m_rdata(im_rdata));
    dcache #(.LINES(16), .LINE_WORDS(LW)) u_dcache (
        .clk(clk), .rst(rst), .addr(daddr), .req(dreq & sel_ram), .we(dwe), .wdata(dwdata),
        .rdata(ram_rdata), .ready(ram_ready),
        .m_req(dm_req), .m_we(dm_we), .m_addr(dm_addr), .m_wdata(dm_wdata),
        .m_done(dm_done), .m_rdata(dm_rdata));
    mem_slow #(.WORDS(ROM_WORDS), .LINE_WORDS(LW), .LATENCY(5)) u_rom (
        .clk(clk), .rst(rst), .req(im_req), .we(1'b0), .burst(1'b1), .addr(im_addr),
        .wmask(4'b0), .wdata({LWB{1'b0}}), .done(im_done), .rdata(im_rdata));
    mem_slow #(.WORDS(RAM_WORDS), .LINE_WORDS(LW), .LATENCY(5)) u_ram (
        .clk(clk), .rst(rst), .req(dm_req), .we(dm_we), .burst(1'b1), .addr(dm_addr),
        .wmask(4'b1111), .wdata(dm_wdata), .done(dm_done), .rdata(dm_rdata));

    // ---- what rvtest_harness.vh needs ---------------------------------
    wire [31:0] rvt_instr  = u_core.ifid_instr;
    wire        rvt_wr     = dreq & (|dwe) & ~sel_ram;    // tohost is MMIO
    wire [31:0] rvt_waddr  = daddr;
    wire [31:0] rvt_wdata  = dwdata;

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
