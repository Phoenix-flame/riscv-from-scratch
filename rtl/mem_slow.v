// =====================================================================
// mem_slow.v  -  a slow, burst-oriented main memory (a DDR stand-in)
// ---------------------------------------------------------------------
// Real main memory does not answer in a cycle. DDR behind a controller
// takes tens of cycles before the first word appears, and then streams
// the following words one per cycle. That shape -- a long first-word
// LATENCY, then cheap sequential beats -- is what makes caches pay off,
// and this model has exactly that shape:
//
//   accept (1) -> wait LATENCY cycles -> N beats, one word each -> done
//
//   burst=1 : a whole line (N = LINE_WORDS), aligned; read or write
//   burst=0 : one word (N = 1), byte-masked write or read
//
// So a single word costs LATENCY+2 cycles from request to `done`, and a
// LINE_WORDS line costs LATENCY+LINE_WORDS+1: eight words for barely
// more than the price of one. The master holds `req` (and its address /
// data) until it sees the one-cycle `done` pulse.
//
// Synthesizable: a word array with one registered read or write per beat.
// =====================================================================
`default_nettype none

module mem_slow #(
    parameter WORDS      = 8192,
    parameter LINE_WORDS = 8,
    parameter LATENCY    = 10,
    parameter INIT_FILE  = ""
) (
    input  wire                     clk,
    input  wire                     rst,
    input  wire                     req,
    input  wire                     we,
    input  wire                     burst,
    input  wire [31:0]              addr,       // byte address
    input  wire [3:0]               wmask,      // single-word writes
    input  wire [32*LINE_WORDS-1:0] wdata,      // line (burst) or word in [31:0]
    output reg                      done,
    output reg  [32*LINE_WORDS-1:0] rdata
);
    localparam AW = $clog2(WORDS);
    localparam LB = $clog2(LINE_WORDS);
    localparam S_IDLE=2'd0, S_WAIT=2'd1, S_XFER=2'd2;

    reg [31:0] mem [0:WORDS-1];
    integer k;
    initial begin
        for (k = 0; k < WORDS; k = k + 1) mem[k] = 32'd0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    reg [1:0]  state;
    reg [15:0] wait_cnt;
    reg [LB:0] beat;
    reg [AW-1:0] base;                  // first word index
    reg        l_we, l_burst;
    reg [3:0]  l_mask;
    reg [32*LINE_WORDS-1:0] l_wdata;

    wire [LB:0]   nbeats = l_burst ? LINE_WORDS : 1;
    wire [AW-1:0] widx   = base + beat[LB-1:0];
    wire [31:0]   wword  = l_wdata[32*beat[LB-1:0] +: 32];

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            state <= S_IDLE; beat <= 0; wait_cnt <= 0;
        end else case (state)
            S_IDLE: if (req && !done) begin
                base    <= burst ? {addr[AW+1:LB+2], {LB{1'b0}}} : addr[AW+1:2];
                l_we    <= we; l_burst <= burst; l_mask <= wmask; l_wdata <= wdata;
                beat    <= 0;
                wait_cnt <= LATENCY;
                state   <= (LATENCY == 0) ? S_XFER : S_WAIT;
            end
            S_WAIT: begin
                wait_cnt <= wait_cnt - 1'b1;
                if (wait_cnt == 1) state <= S_XFER;
            end
            S_XFER: begin
                if (l_we) begin
                    if (l_burst)        mem[widx] <= wword;
                    else begin
                        if (l_mask[0]) mem[widx][7:0]   <= wword[7:0];
                        if (l_mask[1]) mem[widx][15:8]  <= wword[15:8];
                        if (l_mask[2]) mem[widx][23:16] <= wword[23:16];
                        if (l_mask[3]) mem[widx][31:24] <= wword[31:24];
                    end
                end else
                    rdata[32*beat[LB-1:0] +: 32] <= mem[widx];
                if (beat == nbeats - 1) begin done <= 1'b1; state <= S_IDLE; end
                beat <= beat + 1'b1;
            end
            default: state <= S_IDLE;
        endcase
    end
endmodule

`default_nettype wire
