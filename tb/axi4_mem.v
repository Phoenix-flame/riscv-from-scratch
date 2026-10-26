`timescale 1ns/1ps
`default_nettype none
// =====================================================================
// axi4_mem.v  -  an AXI4 slave memory with DDR-like timing (simulation)
// ---------------------------------------------------------------------
// Stands in for the Zynq's DDR behind an S_AXI_HP port. It accepts INCR
// bursts of 32-bit beats, one read and one write engine, and:
//
//   * LATENCY cycles from an accepted AR to the first R beat (and from
//     the last W beat to B), then one beat a cycle;
//   * STALL = 1 drops ready / valid at pseudo-random cycles on every
//     channel, so a master that assumes a beat per cycle -- or that
//     drops a signal before its handshake -- fails;
//   * addresses outside [BASE, BASE + 4*WORDS) answer SLVERR;
//   * protocol checks: a WLAST in the wrong place, or a burst type, size
//     or ID it does not support, is reported and counted in `errors`.
// =====================================================================
module axi4_mem #(
    parameter        WORDS   = 1 << 20,       // 4 MiB
    parameter [31:0] BASE    = 32'd0,
    parameter        LATENCY = 20,
    parameter        STALL   = 1
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] awaddr,
    input  wire [7:0]  awlen,
    input  wire [2:0]  awsize,
    input  wire [1:0]  awburst,
    input  wire        awvalid,
    output reg         awready,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    input  wire        wlast,
    input  wire        wvalid,
    output reg         wready,
    output reg  [1:0]  bresp,
    output reg         bvalid,
    input  wire        bready,
    input  wire [31:0] araddr,
    input  wire [7:0]  arlen,
    input  wire [2:0]  arsize,
    input  wire [1:0]  arburst,
    input  wire        arvalid,
    output reg         arready,
    output reg  [31:0] rdata,
    output reg  [1:0]  rresp,
    output reg         rlast,
    output reg         rvalid,
    input  wire        rready
);
    reg [31:0] mem [0:WORDS-1];
    integer k, errors = 0, reads = 0, writes = 0;
    initial for (k = 0; k < WORDS; k = k + 1) mem[k] = 32'd0;

    reg [15:0] lfsr;
    wire       go = (STALL == 0) | lfsr[0] | lfsr[3];        // ~3/4 of cycles
    always @(posedge clk) lfsr <= rst ? 16'hACE1 : {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};

    function in_range; input [31:0] a; in_range = (a - BASE) < 4 * WORDS; endfunction
    function [31:0] widx; input [31:0] a; widx = (a - BASE) >> 2; endfunction

    // ---- read engine ----
    reg        r_busy;
    reg [31:0] r_addr;
    reg [7:0]  r_left;
    reg [15:0] r_wait;
    wire [31:0] r_next = r_addr + 32'd4;
    always @(posedge clk) begin
        if (rst) begin
            r_busy <= 0; arready <= 0; rvalid <= 0; rlast <= 0; rresp <= 0;
        end else begin
            arready <= ~r_busy & go;
            if (arvalid && arready && !r_busy) begin
                if (arburst != 2'b01 || arsize != 3'd2) begin
                    $display("axi4_mem: unsupported read burst/size %0d/%0d", arburst, arsize);
                    errors = errors + 1;
                end
                r_busy <= 1; r_addr <= araddr; r_left <= arlen; r_wait <= LATENCY;
                arready <= 0; reads = reads + 1;
            end
            if (r_busy) begin
                if (rvalid && rready) begin                 // a beat was taken
                    if (rlast) begin rvalid <= 0; r_busy <= 0; end
                    else begin
                        r_addr <= r_next; r_left <= r_left - 1;
                        if (go) begin                       // the next one at once
                            rdata  <= in_range(r_next) ? mem[widx(r_next)] : 32'hDEADBEEF;
                            rresp  <= in_range(r_next) ? 2'b00 : 2'b10;
                            rlast  <= (r_left == 1);
                        end else rvalid <= 0;
                    end
                end else if (!rvalid) begin
                    if (r_wait != 0) r_wait <= r_wait - 1;
                    else if (go) begin
                        rvalid <= 1;
                        rdata  <= in_range(r_addr) ? mem[widx(r_addr)] : 32'hDEADBEEF;
                        rresp  <= in_range(r_addr) ? 2'b00 : 2'b10;
                        rlast  <= (r_left == 0);
                    end
                end
            end
        end
    end

    // ---- write engine ----
    reg        w_busy, w_have_aw;
    reg [31:0] w_addr;
    reg [7:0]  w_left;
    reg        w_bad;
    reg [15:0] w_wait;
    reg        w_resp_pending;
    always @(posedge clk) begin
        if (rst) begin
            awready <= 0; wready <= 0; bvalid <= 0; bresp <= 0;
            w_have_aw <= 0; w_resp_pending <= 0; w_bad <= 0;
        end else begin
            awready <= ~w_have_aw & ~w_resp_pending & go;
            wready  <= w_have_aw & go;
            if (awvalid && awready && !w_have_aw) begin
                if (awburst != 2'b01 || awsize != 3'd2) begin
                    $display("axi4_mem: unsupported write burst/size %0d/%0d", awburst, awsize);
                    errors = errors + 1;
                end
                w_have_aw <= 1; w_addr <= awaddr; w_left <= awlen; awready <= 0;
                w_bad <= ~in_range(awaddr); wready <= 0; writes = writes + 1;
            end
            if (wvalid && wready && w_have_aw) begin
                if (in_range(w_addr)) begin
                    if (wstrb[0]) mem[widx(w_addr)][7:0]   <= wdata[7:0];
                    if (wstrb[1]) mem[widx(w_addr)][15:8]  <= wdata[15:8];
                    if (wstrb[2]) mem[widx(w_addr)][23:16] <= wdata[23:16];
                    if (wstrb[3]) mem[widx(w_addr)][31:24] <= wdata[31:24];
                end else w_bad <= 1;
                if (wlast != (w_left == 0)) begin
                    $display("axi4_mem: WLAST=%0d with %0d beats left", wlast, w_left);
                    errors = errors + 1;
                end
                w_addr <= w_addr + 4; w_left <= w_left - 1;
                if (wlast) begin
                    w_have_aw <= 0; wready <= 0; w_resp_pending <= 1; w_wait <= LATENCY;
                end
            end
            if (w_resp_pending) begin
                if (w_wait != 0) w_wait <= w_wait - 1;
                else if (!bvalid && go) begin bvalid <= 1; bresp <= w_bad ? 2'b10 : 2'b00; end
                if (bvalid && bready) begin bvalid <= 0; w_resp_pending <= 0; end
            end
        end
    end
endmodule
`default_nettype wire
