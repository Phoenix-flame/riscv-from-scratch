// =====================================================================
// oz_burst_mem.v  -  mem_slow's interface on top of a real block RAM port
// ---------------------------------------------------------------------
// The caches (Step 43) talk to memory in whole-line bursts through the
// mem_slow interface: hold `req` (+ we / burst / addr / data) until a
// one-cycle `done`. In simulation mem_slow modelled DDR latency; on the
// FPGA the backing store is an oz_dpram, and this adapter sequences its
// port A: one word per cycle, plus one cycle at the end of a read for the
// RAM's registered output. A line of LINE_WORDS words costs LINE_WORDS+2
// cycles, a single word (burst=0, the uncached bridge) 3.
// =====================================================================
`default_nettype none

module oz_burst_mem #(
    parameter WORDS      = 4096,
    parameter LINE_WORDS = 8
) (
    input  wire                     clk,
    input  wire                     rst,
    // ---- mem_slow-style master side ----
    input  wire                     req,
    input  wire                     we,
    input  wire                     burst,
    input  wire [31:0]              addr,       // byte address
    input  wire [3:0]               wmask,      // single-word writes
    input  wire [32*LINE_WORDS-1:0] wdata,
    output reg                      done,
    output reg  [32*LINE_WORDS-1:0] rdata,
    // ---- block RAM port ----
    output wire                     ram_en,
    output wire [3:0]               ram_we,
    output wire [$clog2(WORDS)-1:0] ram_addr,
    output wire [31:0]              ram_wdata,
    input  wire [31:0]              ram_rdata
);
    localparam AW = $clog2(WORDS);
    localparam LB = $clog2(LINE_WORDS);
    localparam S_IDLE=2'd0, S_XFER=2'd1, S_LAST=2'd2;

    reg [1:0]    state;
    reg [LB:0]   beat;
    reg [AW-1:0] base;
    reg          l_we, l_burst;
    reg [3:0]    l_mask;
    reg [32*LINE_WORDS-1:0] l_wdata;
    reg          cap_v;                  // a read word arrives next cycle
    reg [LB-1:0] cap_i;

    wire [LB:0] nbeats = l_burst ? LINE_WORDS : 1;
    assign ram_en    = (state == S_XFER);
    assign ram_addr  = base + beat[LB-1:0];
    assign ram_we    = (state == S_XFER && l_we) ? (l_burst ? 4'b1111 : l_mask) : 4'b0000;
    assign ram_wdata = l_wdata[32*beat[LB-1:0] +: 32];

    always @(posedge clk) begin
        done  <= 1'b0;
        cap_v <= 1'b0;
        if (cap_v) rdata[32*cap_i +: 32] <= ram_rdata;
        if (rst) begin
            state <= S_IDLE; beat <= 0;
        end else case (state)
            S_IDLE: if (req && !done) begin
                base    <= burst ? {addr[AW+1:LB+2], {LB{1'b0}}} : addr[AW+1:2];
                l_we    <= we; l_burst <= burst; l_mask <= wmask; l_wdata <= wdata;
                beat    <= 0;
                state   <= S_XFER;
            end
            S_XFER: begin
                cap_v <= ~l_we; cap_i <= beat[LB-1:0];
                beat  <= beat + 1'b1;
                if (beat == nbeats - 1) begin
                    if (l_we) begin done <= 1'b1; state <= S_IDLE; end
                    else      state <= S_LAST;          // last word still in flight
                end
            end
            S_LAST: begin done <= 1'b1; state <= S_IDLE; end
            default: state <= S_IDLE;
        endcase
    end
endmodule

`default_nettype wire
