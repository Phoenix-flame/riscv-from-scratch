`timescale 1ns/1ps
`default_nettype none
// End-to-end: the stall-capable core runs a program that reaches the PS over
// the AXI4-Lite master. soc_axi exposes the master pins; here we connect the
// wait-state slave model (the PS stand-in: DDR + peripheral). The program's
// results, computed only if AXI reads/writes round-trip correctly through the
// stalls, are checked in local RAM.
module axi_tb;
    reg clk=0, rst=1; always #5 clk=~clk;
    wire halted;

    wire [31:0] awaddr, wd, araddr; wire [2:0] awprot, arprot; wire [3:0] ws;
    wire awvalid, awready, wvalid, wready, bvalid, bready;
    wire [1:0] bresp, rresp; wire arvalid, arready, rvalid, rready; wire [31:0] rd;

    soc_axi #(.ROM_WORDS(4096), .RAM_WORDS(2048),
              .IMEM_INIT("sw/axi_demo.hex"), .DMEM_INIT("sw/axi_demo.hex")) dut (
        .clk(clk), .rst(rst), .halted(halted),
        .m_awaddr(awaddr), .m_awprot(awprot), .m_awvalid(awvalid), .m_awready(awready),
        .m_wdata(wd), .m_wstrb(ws), .m_wvalid(wvalid), .m_wready(wready),
        .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready),
        .m_araddr(araddr), .m_arprot(arprot), .m_arvalid(arvalid), .m_arready(arready),
        .m_rdata(rd), .m_rresp(rresp), .m_rvalid(rvalid), .m_rready(rready)
    );
    axi_lite_slave_mem #(.WORDS(256), .AW_WAIT(2), .B_WAIT(3), .R_WAIT(4)) ps (
        .clk(clk), .rst(rst),
        .s_awaddr(awaddr), .s_awprot(awprot), .s_awvalid(awvalid), .s_awready(awready),
        .s_wdata(wd), .s_wstrb(ws), .s_wvalid(wvalid), .s_wready(wready),
        .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
        .s_araddr(araddr), .s_arprot(arprot), .s_arvalid(arvalid), .s_arready(arready),
        .s_rdata(rd), .s_rresp(rresp), .s_rvalid(rvalid), .s_rready(rready)
    );

    function [31:0] rdram; input [31:0] a; rdram = dut.u_ram.mem[a>>2]; endfunction
    integer g, fails;
    initial begin
        repeat(3) @(posedge clk); #1; rst=0;
        g=0; while(!halted && g<2000000) begin @(posedge clk); g=g+1; end

        fails=0;
        if (!halted) begin $display("FAIL: no halt"); fails=fails+1; end
        if (rdram(32'h200)!==32'h0000600D) begin $display("FAIL sentinel=%h",rdram(32'h200)); fails=fails+1; end
        if (rdram(32'h100)!==32'h00010348) begin $display("FAIL R0 (PS DDR sum)=%h exp 00010348",rdram(32'h100)); fails=fails+1; end
        if (rdram(32'h104)!==32'h0000007B) begin $display("FAIL R1 (PS rmw)=%h exp 7b",rdram(32'h104)); fails=fails+1; end
        if (rdram(32'h108)!==32'h00000ACE) begin $display("FAIL R2 (PS readback)=%h exp ace",rdram(32'h108)); fails=fails+1; end

        // also confirm the PS actually holds what we wrote (AXI write reached DDR)
        if (ps.mem[0]!==32'h00001000) begin $display("FAIL PS[0]=%h exp 1000",ps.mem[0]); fails=fails+1; end
        if (ps.mem[20]!==32'd123)     begin $display("FAIL PS[20]=%0d exp 123",ps.mem[20]); fails=fails+1; end

        $display("");
        $display("halt @ %0d cycles; PS sum=0x%h rmw=%0d", g, rdram(32'h100), rdram(32'h104));
        if (fails==0) $display("AXI-SOC: ALL PASS");
        else          $display("AXI-SOC: %0d FAIL", fails);
        $finish;
    end
endmodule
`default_nettype wire
