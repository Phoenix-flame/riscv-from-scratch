// =====================================================================
// mem_bridge.v  -  uncached core port -> mem_slow (the no-cache baseline)
// ---------------------------------------------------------------------
// What the core would see with no cache at all: every fetch, load and
// store becomes its own single-word transaction on slow memory and pays
// the full first-word latency. Used only to measure what the caches buy.
//
//   IDLE -> BUSY (single-word transaction) -> DONE (ready, one cycle)
//
// `ready` is only given if the core is still asking for the same
// address: the I-port may move on (a redirect) while a fetch is in
// flight, and that stale word must not be delivered.
// =====================================================================
`default_nettype none

module mem_bridge #(
    parameter LINE_WORDS = 8
) (
    input  wire                     clk,
    input  wire                     rst,
    // ---- core side ----
    input  wire [31:0]              addr,
    input  wire                     req,
    input  wire [3:0]               we,
    input  wire [31:0]              wdata,
    output wire [31:0]              rdata,
    output wire                     ready,
    // ---- memory side ----
    output reg                      m_req,
    output reg                      m_we,
    output reg  [31:0]              m_addr,
    output reg  [3:0]               m_wmask,
    output wire [32*LINE_WORDS-1:0] m_wdata,
    input  wire                     m_done,
    input  wire [32*LINE_WORDS-1:0] m_rdata
);
    localparam S_IDLE=2'd0, S_BUSY=2'd1, S_DONE=2'd2;
    reg [1:0]  state;
    reg [31:0] l_wdata, l_rdata;

    assign m_wdata = {{(32*LINE_WORDS-32){1'b0}}, l_wdata};
    assign rdata   = l_rdata;
    assign ready   = (state == S_DONE) & req & (addr == m_addr) & (we == m_wmask);

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; m_req <= 1'b0; m_we <= 1'b0; m_addr <= 32'd0; m_wmask <= 4'd0;
        end else case (state)
            S_IDLE: if (req) begin
                m_req <= 1'b1; m_we <= |we; m_addr <= addr; m_wmask <= we; l_wdata <= wdata;
                state <= S_BUSY;
            end
            S_BUSY: if (m_done) begin
                m_req <= 1'b0; l_rdata <= m_rdata[31:0]; state <= S_DONE;
            end
            default: state <= S_IDLE;                  // DONE: one cycle
        endcase
    end
endmodule

`default_nettype wire
