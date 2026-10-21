// =====================================================================
// rvtest_pu_tb.v  -  riscv-tests harness for the unified pipeline
// ---------------------------------------------------------------------
// cpu_pipe_u on ideal memory: a 32 KB combinational instruction ROM and
// a 64 KB combinational word RAM, both always ready. tools/rvtests runs
// it twice: `pipe_u` (the suite as built for every core -- body in M)
// and `pipe_u_vm` (built with -DRVTEST_VM -- body in U with Sv32 on, so
// every fetch and access goes through the TLBs).
// =====================================================================
`timescale 1ns/1ps
`default_nettype none

module rvtest_pu_tb;
    localparam ROM_WORDS = 8192;         // 32 KB instruction ROM
    localparam RAM_WORDS = 16384;        // 64 KB data RAM

    reg clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    wire [31:0] iaddr, irdata, daddr, dwdata, drdata;
    wire        ireq, dreq;
    wire [3:0]  dwe;
    wire [31:0] rvt_pc;

    cpu_pipe_u u_core (
        .clk(clk), .rst(rst), .timer_irq(1'b0), .halt(1'b0),
        .i_addr(iaddr), .i_req(ireq), .i_rdata(irdata), .i_ready(1'b1),
        .d_addr(daddr), .d_req(dreq), .d_we(dwe), .d_wdata(dwdata),
        .d_rdata(drdata), .d_ready(1'b1),
        .pc_out(rvt_pc), .retire()
    );

    reg [31:0] rom [0:ROM_WORDS-1];
    reg [31:0] ram [0:RAM_WORDS-1];
    integer k;
    initial begin
        for (k = 0; k < ROM_WORDS; k = k + 1) rom[k] = 32'd0;
        for (k = 0; k < RAM_WORDS; k = k + 1) ram[k] = 32'd0;
    end
    assign irdata = rom[iaddr[$clog2(ROM_WORDS)+1:2]];

    wire sel_ram = (daddr[31:28] == 4'h0);
    wire [$clog2(RAM_WORDS)-1:0] rw = daddr[$clog2(RAM_WORDS)+1:2];
    assign drdata = ram[rw];
    always @(posedge clk)
        if (dreq && sel_ram) begin
            if (dwe[0]) ram[rw][7:0]   <= dwdata[7:0];
            if (dwe[1]) ram[rw][15:8]  <= dwdata[15:8];
            if (dwe[2]) ram[rw][23:16] <= dwdata[23:16];
            if (dwe[3]) ram[rw][31:24] <= dwdata[31:24];
        end

    // ---- what rvtest_harness.vh needs ---------------------------------
    wire [31:0] rvt_instr  = u_core.ifid_instr;
    wire        rvt_wr     = dreq & (|dwe);
    wire [31:0] rvt_waddr  = daddr;
    wire [31:0] rvt_wdata  = dwdata;

    task rvt_load;
        input [1023:0] romf;
        input [1023:0] ramf;
        input          has_ram;
        begin
            $readmemh(romf, rom);
            if (has_ram) $readmemh(ramf, ram);
        end
    endtask

    `include "tb/rvtest_harness.vh"
endmodule

`default_nettype wire
