// =====================================================================
// rvtest_s6_tb.v  -  riscv-tests harness for the Spartan-6 core
// ---------------------------------------------------------------------
// Driven by tools/rvtests, which registers this core as `s6` (and `s6_sf`
// for the FAST_FETCH=0 variant). The system around the core is the
// minimum the suite needs: one 64 KB unified memory covering both the
// suite's ROM window (0x0000..0x7FFF) and its data window (0x8000..
// 0xFFFF), and nothing else -- a store to the SYSCON address IS the
// verdict, and rvtest_harness.vh catches it on the bus.
//
// The memory is the real s6_ram: port A feeds fetch, port B the data
// bus, one array behind both. That is why this core passes rv32ui-fence_i
// while the parent tutorial's Harvard cores cannot -- a store really can
// become an instruction here.
//
//   -DRVT_S6_SLOW   build with FAST_FETCH=0 (separate FETCH state)
// =====================================================================
`timescale 1ns/1ps
`default_nettype none

module rvtest_s6_tb;
    localparam WORDS = 16384;            // 64 KB, ROM+RAM windows in one array

    reg clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    wire [31:0] iaddr, irdata;
    wire [31:0] daddr, dwdata, drdata;
    wire [3:0]  dwe;
    wire        dre, dready;
    wire [31:0] rvt_pc, rvt_instr;

`ifdef RVT_S6_SLOW
    localparam FAST = 0;
`else
    localparam FAST = 1;
`endif

    s6_core #(
        .RESET_ADDR(32'h0000_0000),
        .ENABLE_M(1), .ENABLE_A(1), .ENABLE_C(1), .ENABLE_U(1),
        .MUL_DSP(0), .FAST_FETCH(FAST)
    ) u_core (
        .clk(clk), .rst(rst),
        .ibus_addr(iaddr), .ibus_rdata(irdata),
        .dbus_addr(daddr), .dbus_we(dwe), .dbus_re(dre),
        .dbus_wdata(dwdata), .dbus_rdata(drdata), .dbus_ready(dready),
        .timer_irq(1'b0), .soft_irq(1'b0), .ext_irq(1'b0),
        .mtime(64'd0), .halt(1'b0),
        .pc_out(rvt_pc), .instr_out(rvt_instr), .retire_out()
    );

    wire sel_ram = (daddr[31:28] == 4'h0);

    s6_ram #(.WORDS(WORDS)) u_mem (
        .clk(clk),
        .a_addr(iaddr[$clog2(WORDS)+1:2]), .a_rdata(irdata),
        .b_addr(daddr[$clog2(WORDS)+1:2]),
        .b_we(sel_ram ? dwe : 4'b0000), .b_wdata(dwdata), .b_rdata(drdata)
    );

    // Writes finish immediately; reads take one wait state and come back
    // registered -- the protocol s6_soc implements for every slave.
    reg ram_rack;
    always @(posedge clk) ram_rack <= rst ? 1'b0 : (sel_ram & dre & ~ram_rack);
    assign dready = sel_ram ? ((|dwe) | ram_rack) : 1'b1;

    // ---- what rvtest_harness.vh needs ---------------------------------
    wire       rvt_wr    = |dwe;
    wire [31:0] rvt_waddr = daddr;
    wire [31:0] rvt_wdata = dwdata;

    // One flat address space, so only the RAM image is needed: the runner
    // already puts .text at 0 and .data at 0x8000 in it.
    task rvt_load;
        input [1023:0] romf;
        input [1023:0] ramf;
        input          has_ram;
        begin
            if (has_ram) $readmemh(ramf, u_mem.mem);
            else         $readmemh(romf, u_mem.mem);
        end
    endtask

    `include "tb/rvtest_harness.vh"
endmodule

`default_nettype wire
