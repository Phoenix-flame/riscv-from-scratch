`timescale 1ns/1ps
`default_nettype none
// =====================================================================
// ps7_hp0_model.v  -  just enough of the Zynq PS7 to simulate fpga_top_linux
// ---------------------------------------------------------------------
// The PS7 hard macro has no simulation model in the open flow. This one
// provides the ports OpenZynq's ps7_gp0 connects, behaving as the PS would
// after `make run` (Step 54):
//
//   * FCLK_CLK0 at 100 MHz; FCLK_RESET0_N released after a while;
//   * FCLK_CLK1 at 11.11 MHz, the RISC-V's clock (the PS program sets
//     IO PLL / 90; Step 57);
//   * S_AXI_HP0 held in reset until ps7_init() would have trained the
//     DDR (HP0_READY_NS), then served by axi4_mem with 64-bit beats -- the
//     DDR window of the PS map at DDR_BASE, with DDR-like latency and
//     random stalls -- one transaction a direction, IDs echoed as 0;
//   * on M_AXI_GP0, what the PS program does after ps7_init(): read the
//     ID at 0x4000_0000 (left in gp0_id), then write run = 1 there
//     (gp0_run set from then on) to release the RISC-V. +NO_RUN skips the
//     write: the negative control, in which the RISC-V must stay in reset.
//
// And BUFG, which ps7_gp0 puts on FCLK0 and FCLK1.
// =====================================================================
module BUFG (input wire I, output wire O);
    assign O = I;
endmodule

module PS7 #(
    parameter        DDR_WORDS    = 1 << 24,          // 64 MiB
    parameter [31:0] DDR_BASE     = 32'h1000_0000,
    parameter        HP0_READY_NS = 5000
) (
    output wire [3:0]  FCLKCLK,
    output wire [3:0]  FCLKRESETN,
    // M_AXI_GP0 (the PS is the master)
    input  wire        MAXIGP0ACLK,
    output wire        MAXIGP0ARESETN,
    output wire [11:0] MAXIGP0AWID,
    output wire [31:0] MAXIGP0AWADDR,
    output wire [3:0]  MAXIGP0AWLEN,
    output wire        MAXIGP0AWVALID,
    input  wire        MAXIGP0AWREADY,
    output wire [31:0] MAXIGP0WDATA,
    output wire [3:0]  MAXIGP0WSTRB,
    output wire        MAXIGP0WLAST,
    output wire        MAXIGP0WVALID,
    input  wire        MAXIGP0WREADY,
    input  wire [11:0] MAXIGP0BID,
    input  wire [1:0]  MAXIGP0BRESP,
    input  wire        MAXIGP0BVALID,
    output wire        MAXIGP0BREADY,
    output wire [11:0] MAXIGP0ARID,
    output reg  [31:0] MAXIGP0ARADDR,
    output wire [3:0]  MAXIGP0ARLEN,
    output reg         MAXIGP0ARVALID,
    input  wire        MAXIGP0ARREADY,
    input  wire [11:0] MAXIGP0RID,
    input  wire [31:0] MAXIGP0RDATA,
    input  wire [1:0]  MAXIGP0RRESP,
    input  wire        MAXIGP0RLAST,
    input  wire        MAXIGP0RVALID,
    output reg         MAXIGP0RREADY,
    // S_AXI_HP0 (the PL is the master)
    input  wire        SAXIHP0ACLK,
    output reg         SAXIHP0ARESETN,
    input  wire [5:0]  SAXIHP0AWID,
    input  wire [31:0] SAXIHP0AWADDR,
    input  wire [3:0]  SAXIHP0AWLEN,
    input  wire [1:0]  SAXIHP0AWSIZE,
    input  wire [1:0]  SAXIHP0AWBURST,
    input  wire [1:0]  SAXIHP0AWLOCK,
    input  wire [3:0]  SAXIHP0AWCACHE,
    input  wire [2:0]  SAXIHP0AWPROT,
    input  wire [3:0]  SAXIHP0AWQOS,
    input  wire        SAXIHP0AWVALID,
    output wire        SAXIHP0AWREADY,
    input  wire [5:0]  SAXIHP0WID,
    input  wire [63:0] SAXIHP0WDATA,
    input  wire [7:0]  SAXIHP0WSTRB,
    input  wire        SAXIHP0WLAST,
    input  wire        SAXIHP0WVALID,
    output wire        SAXIHP0WREADY,
    output wire [5:0]  SAXIHP0BID,
    output wire [1:0]  SAXIHP0BRESP,
    output wire        SAXIHP0BVALID,
    input  wire        SAXIHP0BREADY,
    input  wire [5:0]  SAXIHP0ARID,
    input  wire [31:0] SAXIHP0ARADDR,
    input  wire [3:0]  SAXIHP0ARLEN,
    input  wire [1:0]  SAXIHP0ARSIZE,
    input  wire [1:0]  SAXIHP0ARBURST,
    input  wire [1:0]  SAXIHP0ARLOCK,
    input  wire [3:0]  SAXIHP0ARCACHE,
    input  wire [2:0]  SAXIHP0ARPROT,
    input  wire [3:0]  SAXIHP0ARQOS,
    input  wire        SAXIHP0ARVALID,
    output wire        SAXIHP0ARREADY,
    output wire [5:0]  SAXIHP0RID,
    output wire [63:0] SAXIHP0RDATA,
    output wire [1:0]  SAXIHP0RRESP,
    output wire        SAXIHP0RLAST,
    output wire        SAXIHP0RVALID,
    input  wire        SAXIHP0RREADY,
    input  wire        SAXIHP0RDISSUECAP1EN,
    input  wire        SAXIHP0WRISSUECAP1EN
);
    // ---- clocks and resets ----
    reg fclk0 = 1'b0, fresetn = 1'b0;
    always #5 fclk0 = ~fclk0;                              // 100 MHz
    reg fclk1 = 1'b0;
    always #45 fclk1 = ~fclk1;                             // 11.11 MHz
    initial begin
        SAXIHP0ARESETN = 1'b0;
        #200 fresetn = 1'b1;
        #(HP0_READY_NS) SAXIHP0ARESETN = 1'b1;             // "ps7_init() is done"
    end
    assign FCLKCLK = {2'b00, fclk1, fclk0};
    assign FCLKRESETN = {3'b111, fresetn};
    assign MAXIGP0ARESETN = fresetn;

    // ---- GP0: one read of the PL's ID register ----
    reg        aw_v = 1'b0, w_v = 1'b0;
    assign MAXIGP0AWID = 12'd0; assign MAXIGP0AWADDR = 32'h4000_0000; assign MAXIGP0AWLEN = 4'd0;
    assign MAXIGP0AWVALID = aw_v; assign MAXIGP0WDATA = 32'd1; assign MAXIGP0WSTRB = 4'hF;
    assign MAXIGP0WLAST = 1'b1; assign MAXIGP0WVALID = w_v; assign MAXIGP0BREADY = 1'b1;
    assign MAXIGP0ARID = 12'd0; assign MAXIGP0ARLEN = 4'd0;
    reg [31:0] gp0_id = 32'd0;
    reg        gp0_done = 1'b0, gp0_run = 1'b0;
    // driven and sampled on the falling edge, half a cycle from where the
    // PL changes anything: a valid & ready seen there is a handshake on the
    // next rising edge
    initial begin
        MAXIGP0ARVALID = 1'b0; MAXIGP0RREADY = 1'b0; MAXIGP0ARADDR = 32'h4000_0000;
        #1000 @(negedge fclk0);
        MAXIGP0ARVALID = 1'b1; MAXIGP0RREADY = 1'b1;
        while (!MAXIGP0ARREADY) @(negedge fclk0);
        @(negedge fclk0) MAXIGP0ARVALID = 1'b0;
        while (!MAXIGP0RVALID) @(negedge fclk0);
        gp0_id = MAXIGP0RDATA; gp0_done = 1'b1;
        $display("ps7 model: GP0 read of 0x40000000 -> 0x%08x", gp0_id);
        @(negedge fclk0) MAXIGP0RREADY = 1'b0;
        // ... and once "ps7_init()" is done, release the RISC-V (+NO_RUN: never)
        if (!$test$plusargs("NO_RUN")) begin
            while (!SAXIHP0ARESETN) @(negedge fclk0);
            repeat (50) @(negedge fclk0);
            aw_v = 1'b1; w_v = 1'b1;                   // AW and W complete independently
            while (aw_v || w_v) begin
                if (aw_v && MAXIGP0AWREADY) begin @(posedge fclk0); #1 aw_v = 1'b0; end
                else if (w_v && MAXIGP0WREADY) begin @(posedge fclk0); #1 w_v = 1'b0; end
                else @(negedge fclk0);
            end
            while (!MAXIGP0BVALID) @(negedge fclk0);
            gp0_run = 1'b1;
            $display("ps7 model: wrote run = 1 to 0x40000000");
        end
    end

    // ---- HP0: the DDR window ----
    axi4_mem #(.WORDS(DDR_WORDS), .BASE(DDR_BASE), .LATENCY(24), .STALL(1), .DATA_W(64)) u_ddr (
        .clk(SAXIHP0ACLK), .rst(~SAXIHP0ARESETN),
        .awaddr(SAXIHP0AWADDR), .awlen({4'd0, SAXIHP0AWLEN}), .awsize({1'b0, SAXIHP0AWSIZE}),
        .awburst(SAXIHP0AWBURST), .awvalid(SAXIHP0AWVALID), .awready(SAXIHP0AWREADY),
        .wdata(SAXIHP0WDATA), .wstrb(SAXIHP0WSTRB), .wlast(SAXIHP0WLAST), .wvalid(SAXIHP0WVALID),
        .wready(SAXIHP0WREADY), .bresp(SAXIHP0BRESP), .bvalid(SAXIHP0BVALID), .bready(SAXIHP0BREADY),
        .araddr(SAXIHP0ARADDR), .arlen({4'd0, SAXIHP0ARLEN}), .arsize({1'b0, SAXIHP0ARSIZE}),
        .arburst(SAXIHP0ARBURST), .arvalid(SAXIHP0ARVALID), .arready(SAXIHP0ARREADY),
        .rdata(SAXIHP0RDATA), .rresp(SAXIHP0RRESP), .rlast(SAXIHP0RLAST), .rvalid(SAXIHP0RVALID),
        .rready(SAXIHP0RREADY));
    assign SAXIHP0BID = 6'd0;
    assign SAXIHP0RID = 6'd0;

    // the PL must not use HP0 before the PS has released it, nor with IDs
    // or locks this design never sends
    integer hp0_misuse = 0;
    always @(posedge SAXIHP0ACLK) begin
        if (!SAXIHP0ARESETN && (SAXIHP0AWVALID === 1'b1 || SAXIHP0ARVALID === 1'b1 || SAXIHP0WVALID === 1'b1))
            hp0_misuse = hp0_misuse + 1;
        if ((SAXIHP0AWVALID === 1'b1 && (SAXIHP0AWID != 0 || SAXIHP0AWLOCK != 0)) ||
            (SAXIHP0ARVALID === 1'b1 && (SAXIHP0ARID != 0 || SAXIHP0ARLOCK != 0)) ||
            (SAXIHP0WVALID === 1'b1 && SAXIHP0WID != 0))
            hp0_misuse = hp0_misuse + 1;
    end
endmodule
`default_nettype wire
