`timescale 1ns/1ps
`default_nettype none
// AXI4-Lite slave model standing in for the Zynq PS (a slab of DDR + a
// peripheral). It is deliberately slow and bursty in its readiness: the
// AW/AR accept and the B/R response each wait a parameterizable number of
// cycles, so the master and the stall-capable core have to cope with real
// variable latency rather than a fixed pipe. Single 32-bit beats (AXI4-Lite).
module axi_lite_slave_mem #(
    parameter WORDS   = 4096,
    parameter AW_WAIT = 2,        // cycles before accepting write/read address
    parameter B_WAIT  = 3,        // cycles before the write response
    parameter R_WAIT  = 4         // cycles before read data
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] s_awaddr,
    input  wire [2:0]  s_awprot,
    input  wire        s_awvalid,
    output reg         s_awready,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wvalid,
    output reg         s_wready,
    output reg  [1:0]  s_bresp,
    output reg         s_bvalid,
    input  wire        s_bready,
    input  wire [31:0] s_araddr,
    input  wire [2:0]  s_arprot,
    input  wire        s_arvalid,
    output reg         s_arready,
    output reg  [31:0] s_rdata,
    output reg  [1:0]  s_rresp,
    output reg         s_rvalid,
    input  wire        s_rready
);
    reg [31:0] mem [0:WORDS-1];
    integer i;
    initial for (i=0;i<WORDS;i=i+1) mem[i]=32'd0;

    function [31:0] widx; input [31:0] a; widx = (a >> 2) & (WORDS-1); endfunction

    localparam W_IDLE=0, W_WAIT=1, W_RESP=2;
    localparam R_IDLE=0, R_WAITA=1, R_RESP=2;
    integer wst, rst_s, wcnt, rcnt;
    reg [31:0] waddr_l, raddr_l, wdata_l;
    reg [3:0]  wstrb_l;

    always @(posedge clk) begin
        if (rst) begin
            s_awready<=0; s_wready<=0; s_bvalid<=0; s_bresp<=2'b00;
            s_arready<=0; s_rvalid<=0; s_rresp<=2'b00; s_rdata<=0;
            wst<=W_IDLE; rst_s<=R_IDLE; wcnt<=0; rcnt<=0;
        end else begin
            // ---------------- write channel ----------------
            s_awready<=0; s_wready<=0;
            case (wst)
                W_IDLE: if (s_awvalid && s_wvalid) begin
                    waddr_l<=s_awaddr; wdata_l<=s_wdata; wstrb_l<=s_wstrb;
                    wcnt<=AW_WAIT; wst<=W_WAIT;
                end
                W_WAIT: if (wcnt==0) begin
                    s_awready<=1; s_wready<=1;            // accept AW+W together
                    // commit the write (byte strobes)
                    if (wstrb_l[0]) mem[widx(waddr_l)][ 7: 0]<=wdata_l[ 7: 0];
                    if (wstrb_l[1]) mem[widx(waddr_l)][15: 8]<=wdata_l[15: 8];
                    if (wstrb_l[2]) mem[widx(waddr_l)][23:16]<=wdata_l[23:16];
                    if (wstrb_l[3]) mem[widx(waddr_l)][31:24]<=wdata_l[31:24];
                    wcnt<=B_WAIT; wst<=W_RESP;
                end else wcnt<=wcnt-1;
                W_RESP: begin
                    if (wcnt==0) begin s_bvalid<=1; s_bresp<=2'b00; end
                    else wcnt<=wcnt-1;
                    if (s_bvalid && s_bready) begin s_bvalid<=0; wst<=W_IDLE; end
                end
            endcase

            // ---------------- read channel ----------------
            s_arready<=0;
            case (rst_s)
                R_IDLE: if (s_arvalid) begin
                    raddr_l<=s_araddr; rcnt<=AW_WAIT; rst_s<=R_WAITA;
                end
                R_WAITA: if (rcnt==0) begin
                    s_arready<=1;                         // accept AR
                    rcnt<=R_WAIT; rst_s<=R_RESP;
                end else rcnt<=rcnt-1;
                R_RESP: begin
                    if (rcnt==0) begin
                        s_rvalid<=1; s_rresp<=2'b00; s_rdata<=mem[widx(raddr_l)];
                    end else rcnt<=rcnt-1;
                    if (s_rvalid && s_rready) begin s_rvalid<=0; rst_s<=R_IDLE; end
                end
            endcase
        end
    end
endmodule
`default_nettype wire
