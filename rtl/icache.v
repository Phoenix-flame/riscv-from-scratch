// =====================================================================
// icache.v  -  direct-mapped instruction cache
// ---------------------------------------------------------------------
// Sits between the core's I-port (ready/valid, Step 42) and slow memory
// (mem_slow). LINES lines of LINE_WORDS words; the address splits as
//
//   | tag | index (log2 LINES) | word (log2 LINE_WORDS) | 00 |
//
// Hit: `ready` the same cycle, instruction straight from the line array
// (a small combinational-read array -- LUTRAM on an FPGA), so a hit
// costs the pipeline nothing. Miss: one burst read of the whole line,
// install it, and the next cycle hits. The refill always completes even
// if the core moves to another address meanwhile (a branch redirect);
// the cache then simply looks the new address up.
//
// Instructions are read-only here, so there is no write path and no
// dirty state; fence.i coherence with the D-side is out of scope (the
// instruction memory is write-once, as on every core in this project).
// =====================================================================
`default_nettype none

module icache #(
    parameter LINES      = 32,
    parameter LINE_WORDS = 8
) (
    input  wire                     clk,
    input  wire                     rst,
    // ---- core side ----
    input  wire [31:0]              addr,
    input  wire                     req,
    output wire [31:0]              rdata,
    output wire                     ready,
    // ---- memory side ----
    output reg                      m_req,
    output wire [31:0]              m_addr,
    input  wire                     m_done,
    input  wire [32*LINE_WORDS-1:0] m_rdata
);
    localparam OFF = $clog2(LINE_WORDS) + 2;
    localparam IDX = $clog2(LINES);
    localparam TAG = 32 - OFF - IDX;

    reg [LINES-1:0]          valid;
    reg [TAG-1:0]            tags  [0:LINES-1];
    reg [32*LINE_WORDS-1:0]  lines [0:LINES-1];

    wire [IDX-1:0] idx  = addr[OFF+IDX-1:OFF];
    wire [TAG-1:0] tag  = addr[31:OFF+IDX];
    wire [OFF-3:0] word = addr[OFF-1:2];
    wire [32*LINE_WORDS-1:0] line = lines[idx];
    wire hit = valid[idx] & (tags[idx] == tag);

    reg        filling;
    reg [31:0] miss_addr;
    assign m_addr = {miss_addr[31:OFF], {OFF{1'b0}}};
    assign rdata  = line[32*word +: 32];
    assign ready  = req & hit & ~filling;

    // statistics (simulation visibility; harmless in hardware)
    reg [31:0] n_hit, n_miss;

    always @(posedge clk) begin
        if (rst) begin
            valid <= {LINES{1'b0}}; filling <= 1'b0; m_req <= 1'b0;
            miss_addr <= 32'd0; n_hit <= 0; n_miss <= 0;
        end else if (!filling) begin
            if (req & hit) n_hit <= n_hit + 1;
            if (req & ~hit) begin
                miss_addr <= addr; m_req <= 1'b1; filling <= 1'b1; n_miss <= n_miss + 1;
            end
        end else if (m_done) begin
            lines[miss_addr[OFF+IDX-1:OFF]] <= m_rdata;
            tags [miss_addr[OFF+IDX-1:OFF]] <= miss_addr[31:OFF+IDX];
            valid[miss_addr[OFF+IDX-1:OFF]] <= 1'b1;
            m_req <= 1'b0; filling <= 1'b0;
        end
    end
endmodule

`default_nettype wire
