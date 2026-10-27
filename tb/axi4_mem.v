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
//
// DATA_W = 64 (Step 54) models a Zynq S_AXI_HP port: 8-byte beats (size
// 3), two words of the array each, and AXI3's limit of 16 beats a burst
// (checked). The array stays in 32-bit words either way.
// =====================================================================
module axi4_mem #(
    parameter        WORDS   = 1 << 20,       // 4 MiB
    parameter [31:0] BASE    = 32'd0,
    parameter        LATENCY = 20,
    parameter        STALL   = 1,
    parameter        DATA_W  = 32             // 32, or 64 (an S_AXI_HP port)
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] awaddr,
    input  wire [7:0]  awlen,
    input  wire [2:0]  awsize,
    input  wire [1:0]  awburst,
    input  wire        awvalid,
    output reg         awready,
    input  wire [DATA_W-1:0]   wdata,
    input  wire [DATA_W/8-1:0] wstrb,
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
    output reg  [DATA_W-1:0]   rdata,
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

    localparam [2:0]  SIZE = (DATA_W == 64) ? 3'd3 : 3'd2;
    localparam [31:0] STEP = DATA_W / 8;
    function in_range; input [31:0] a; in_range = (a - BASE) < 4 * WORDS; endfunction
    function [31:0] widx; input [31:0] a; widx = (a - BASE) >> 2; endfunction
    // one beat of the array: the word at a, and for 64 bits the next one above
    function [DATA_W-1:0] beat_at; input [31:0] a; begin
        if (!in_range(a))      beat_at = {DATA_W/32{32'hDEADBEEF}};
        else if (DATA_W == 64) beat_at = {mem[widx(a) + 1], mem[widx(a)]};
        else                   beat_at = mem[widx(a)];
    end endfunction
    // a burst this port cannot take: wrong type, size or alignment, or
    // (AXI3, 64-bit) more than 16 beats
    function bad_burst; input [1:0] burst; input [2:0] size; input [7:0] len; input [31:0] a;
        bad_burst = burst != 2'b01 || size != SIZE || (a & (STEP - 1)) != 0 ||
                    (DATA_W == 64 && len > 8'd15);
    endfunction

    // ---- read engine ----
    reg        r_busy;
    reg [31:0] r_addr;
    reg [7:0]  r_left;
    reg [15:0] r_wait;
    wire [31:0] r_next = r_addr + STEP;
    always @(posedge clk) begin
        if (rst) begin
            r_busy <= 0; arready <= 0; rvalid <= 0; rlast <= 0; rresp <= 0;
        end else begin
            arready <= ~r_busy & go;
            if (arvalid && arready && !r_busy) begin
                if (bad_burst(arburst, arsize, arlen, araddr)) begin
                    $display("axi4_mem: unsupported read burst/size/len %0d/%0d/%0d at %h",
                             arburst, arsize, arlen, araddr);
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
                            rdata  <= beat_at(r_next);
                            rresp  <= in_range(r_next) ? 2'b00 : 2'b10;
                            rlast  <= (r_left == 1);
                        end else rvalid <= 0;
                    end
                end else if (!rvalid) begin
                    if (r_wait != 0) r_wait <= r_wait - 1;
                    else if (go) begin
                        rvalid <= 1;
                        rdata  <= beat_at(r_addr);
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
                if (bad_burst(awburst, awsize, awlen, awaddr)) begin
                    $display("axi4_mem: unsupported write burst/size/len %0d/%0d/%0d at %h",
                             awburst, awsize, awlen, awaddr);
                    errors = errors + 1;
                end
                w_have_aw <= 1; w_addr <= awaddr; w_left <= awlen; awready <= 0;
                w_bad <= ~in_range(awaddr); wready <= 0; writes = writes + 1;
            end
            if (wvalid && wready && w_have_aw) begin
                if (in_range(w_addr)) begin
                    for (k = 0; k < DATA_W / 8; k = k + 1)
                        if (wstrb[k]) mem[widx(w_addr) + k / 4][8 * (k % 4) +: 8] <= wdata[8 * k +: 8];
                end else w_bad <= 1;
                if (wlast != (w_left == 0)) begin
                    $display("axi4_mem: WLAST=%0d with %0d beats left", wlast, w_left);
                    errors = errors + 1;
                end
                w_addr <= w_addr + STEP; w_left <= w_left - 1;
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
