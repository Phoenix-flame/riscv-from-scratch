// =====================================================================
// s6_sram.v  -  Driver for the IS61WV5128BLL asynchronous SRAM (512K x 8)
// ---------------------------------------------------------------------
// The Posedge One carries an ISSI IS61WV5128BLL: 4 Mbit organised as
// 512K x 8, 3.3 V, asynchronous, with just /CE, /OE and /WE -- no clock,
// no byte enables (the part is already byte wide). 19 address lines and
// 8 data lines reach the FPGA, which is exactly what the board's UCF
// brings out. That is 512 KB of memory next to the LX9's 72 KB of block
// RAM, so this is where a program puts its heap, its buffers and any
// data set too big to keep on chip.
//
// A 32-bit bus access therefore becomes four byte accesses. Reads walk
// bytes 0..3; writes walk only the bytes the write mask enables, so a
// `sb` costs one byte cycle rather than four.
//
// ---- timing -------------------------------------------------------------
// The part is asynchronous, so the controller counts clock cycles:
//
//   read   /CE and /OE low, address stable for RD_CYCLES clocks, then the
//          data is sampled. Needs RD_CYCLES * Tclk >= tAA + tCO(FPGA) +
//          tSU(FPGA). The -10 grade has tAA = 10 ns, so two clocks at
//          48 MHz (41.6 ns) is roughly 4x margin.
//
//   write  one clock of address+data setup with /WE high, WR_CYCLES
//          clocks of /WE low (tWP is 8 ns on the -10 grade), one clock of
//          address+data hold with /WE high. Driving /WE rather than /CE
//          is what keeps the address and data settled around the pulse.
//
// Raise RD_CYCLES / WR_CYCLES if you clock the SoC faster or fit a slower
// speed grade; they are the only two numbers that need to change.
//
// ---- bus ---------------------------------------------------------------
// The core holds addr/we/re until it sees `ready`, so the controller
// latches the request on the first cycle and ignores the strobe until it
// has finished. `ready` pulses for exactly one cycle with the read data.
//
// The bidirectional data pins are NOT tristated here: the top level owns
// the IOBUF, and this module exports sram_dout / sram_doe / sram_din.
// =====================================================================
`default_nettype none

module s6_sram #(
    parameter RD_CYCLES = 2,           // clocks of address+/OE before sampling
    parameter WR_CYCLES = 2            // clocks of /WE low
) (
    input  wire        clk,
    input  wire        rst,

    // ---- bus ----
    input  wire        sel,
    input  wire        re,
    input  wire [3:0]  be,
    input  wire [18:0] addr,           // byte address inside the SRAM
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    output wire        ready,

    // ---- pins (tristate lives in the top level) ----
    output wire [18:0] sram_a,
    output wire [7:0]  sram_dout,
    input  wire [7:0]  sram_din,
    output wire        sram_doe,
    output wire        sram_ce_n,
    output wire        sram_oe_n,
    output wire        sram_we_n
);
    localparam ST_IDLE = 3'd0, ST_RD    = 3'd1, ST_WSET = 3'd2,
               ST_WPUL = 3'd3, ST_WHOLD = 3'd4, ST_ACK  = 3'd5;

    reg [2:0]  st;
    reg [1:0]  bi;                     // which byte of the word
    reg [7:0]  cnt;
    reg [16:0] word_a;
    reg [31:0] wbuf;
    reg [3:0]  bebuf;
    reg        is_wr;

    wire start = sel & (re | (|be)) & (st == ST_IDLE);

    // walk to the next byte lane, or finish
    wire last_byte = (bi == 2'd3);

    always @(posedge clk) begin
        if (rst) begin
            st <= ST_IDLE; bi <= 2'd0; cnt <= 8'd0;
            word_a <= 17'd0; wbuf <= 32'd0; bebuf <= 4'd0;
            is_wr <= 1'b0; rdata <= 32'd0;
        end else begin
            case (st)
                ST_IDLE: if (start) begin
                    word_a <= addr[18:2];
                    wbuf   <= wdata;
                    bebuf  <= be;
                    is_wr  <= |be;
                    bi     <= 2'd0;
                    cnt    <= 8'd0;
                    st     <= (|be) ? ST_WSET : ST_RD;
                end

                // ---- read: hold the address, then sample --------------
                ST_RD: begin
                    if (cnt == (RD_CYCLES - 1)) begin
                        case (bi)
                            2'd0: rdata[7:0]   <= sram_din;
                            2'd1: rdata[15:8]  <= sram_din;
                            2'd2: rdata[23:16] <= sram_din;
                            2'd3: rdata[31:24] <= sram_din;
                        endcase
                        cnt <= 8'd0;
                        if (last_byte) st <= ST_ACK;
                        else           bi <= bi + 2'd1;
                    end else
                        cnt <= cnt + 8'd1;
                end

                // ---- write: setup / pulse / hold, skipping masked bytes
                ST_WSET: begin
                    cnt <= 8'd0;
                    if (!bebuf[bi]) begin
                        if (last_byte) st <= ST_ACK;
                        else           bi <= bi + 2'd1;
                    end else
                        st <= ST_WPUL;
                end

                ST_WPUL: begin
                    if (cnt == (WR_CYCLES - 1)) begin
                        cnt <= 8'd0;
                        st  <= ST_WHOLD;
                    end else
                        cnt <= cnt + 8'd1;
                end

                ST_WHOLD: begin
                    if (last_byte) st <= ST_ACK;
                    else begin bi <= bi + 2'd1; st <= ST_WSET; end
                end

                ST_ACK: st <= ST_IDLE;

                default: st <= ST_IDLE;
            endcase
        end
    end

    assign ready = (st == ST_ACK);

    // ---- pins ----
    wire writing = (st == ST_WSET) | (st == ST_WPUL) | (st == ST_WHOLD);
    assign sram_a     = {word_a, bi};
    assign sram_ce_n  = ~((st == ST_RD) | writing);
    assign sram_oe_n  = ~(st == ST_RD);
    assign sram_we_n  = ~(st == ST_WPUL);
    assign sram_doe   = writing;
    assign sram_dout  = (bi == 2'd0) ? wbuf[7:0]   :
                        (bi == 2'd1) ? wbuf[15:8]  :
                        (bi == 2'd2) ? wbuf[23:16] : wbuf[31:24];
endmodule

`default_nettype wire
