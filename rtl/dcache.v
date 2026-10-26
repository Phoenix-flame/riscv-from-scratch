// =====================================================================
// dcache.v  -  direct-mapped, write-back, write-allocate data cache
// ---------------------------------------------------------------------
// Sits between the core's D-port (ready/valid, byte-lane write mask)
// and slow memory (mem_slow). Same geometry as icache.v:
//
//   | tag | index (log2 LINES) | word (log2 LINE_WORDS) | byte |
//
//   read  hit : ready the same cycle, word from the line array
//   write hit : ready the same cycle; the bytes are merged into the line
//               at the clock edge and the line is marked DIRTY -- main
//               memory is not touched (write-back)
//   miss      : if the victim line is valid and dirty, burst-write it
//               back first (WB); then burst-read the wanted line (FILL),
//               install it clean, and the retried access hits. A write
//               miss allocates the line the same way (write-allocate).
//
// `clean` (Step 51, for FENCE.I on a memory shared with the I-side)
// writes every dirty line back, one burst each, and keeps them valid and
// now clean; `clean_done` stays up while `clean` does once that is over.
// It starts only between accesses, never in the middle of a miss.
//
// Memory only ever sees whole-line bursts, which is what a DDR
// controller wants. The core holds its request (address, mask, data)
// until `ready`, so nothing needs to be latched on the core side.
// Only cacheable RAM comes here: the SoC sends MMIO around the cache.
// =====================================================================
`default_nettype none

module dcache #(
    parameter LINES      = 64,
    parameter LINE_WORDS = 8
) (
    input  wire                     clk,
    input  wire                     rst,
    // ---- core side ----
    input  wire [31:0]              addr,
    input  wire                     req,
    input  wire [3:0]               we,          // 0 = read
    input  wire [31:0]              wdata,
    output wire [31:0]              rdata,
    output wire                     ready,
    input  wire                     clean,       // write back every dirty line (FENCE.I)
    output wire                     clean_done,
    // ---- memory side ----
    output reg                      m_req,
    output reg                      m_we,
    output reg  [31:0]              m_addr,
    output wire [32*LINE_WORDS-1:0] m_wdata,
    input  wire                     m_done,
    input  wire [32*LINE_WORDS-1:0] m_rdata
);
    localparam OFF = $clog2(LINE_WORDS) + 2;
    localparam IDX = $clog2(LINES);
    localparam TAG = 32 - OFF - IDX;
    localparam S_IDLE=2'd0, S_WB=2'd1, S_FILL=2'd2, S_CLEAN=2'd3;

    reg [LINES-1:0]          valid, dirty;
    reg [TAG-1:0]            tags  [0:LINES-1];
    reg [32*LINE_WORDS-1:0]  lines [0:LINES-1];

    wire [IDX-1:0] idx  = addr[OFF+IDX-1:OFF];
    wire [TAG-1:0] tag  = addr[31:OFF+IDX];
    wire [OFF-3:0] word = addr[OFF-1:2];
    wire [32*LINE_WORDS-1:0] line = lines[idx];
    wire hit = valid[idx] & (tags[idx] == tag);

    reg [1:0] state;
    reg [IDX:0] ci;                              // clean: the line being looked at
    reg         cwb, cleaned;                    // ... being written back; all done
    assign rdata   = line[32*word +: 32];
    assign ready   = req & hit & (state == S_IDLE);
    assign m_wdata = (state == S_CLEAN) ? lines[ci[IDX-1:0]] : line;   // the victim
    assign clean_done = clean & cleaned;

    // write-hit merge: the addressed word with the masked bytes replaced
    wire [31:0] old_w = line[32*word +: 32];
    wire [31:0] new_w = { we[3] ? wdata[31:24] : old_w[31:24],
                          we[2] ? wdata[23:16] : old_w[23:16],
                          we[1] ? wdata[15:8]  : old_w[15:8],
                          we[0] ? wdata[7:0]   : old_w[7:0] };

    reg [31:0] n_hit, n_miss, n_wb;              // statistics

    always @(posedge clk) begin
        if (rst) begin
            valid <= {LINES{1'b0}}; dirty <= {LINES{1'b0}};
            state <= S_IDLE; m_req <= 1'b0; m_we <= 1'b0; m_addr <= 32'd0;
            n_hit <= 0; n_miss <= 0; n_wb <= 0; ci <= 0; cwb <= 1'b0; cleaned <= 1'b0;
        end else begin
          if (!clean) cleaned <= 1'b0;
          case (state)
            S_IDLE: if (clean && !cleaned && !req) begin
                ci <= 0; cwb <= 1'b0; state <= S_CLEAN;
            end else if (req) begin
                if (hit) begin
                    n_hit <= n_hit + 1;
                    if (|we) begin
                        lines[idx] <= (line & ~({{(32*LINE_WORDS-32){1'b0}}, 32'hFFFF_FFFF} << (32*word)))
                                    | ({{(32*LINE_WORDS-32){1'b0}}, new_w} << (32*word));
                        dirty[idx] <= 1'b1;
                    end
                end else begin
                    n_miss <= n_miss + 1;
                    m_req  <= 1'b1;
                    if (valid[idx] & dirty[idx]) begin          // evict first
                        m_we <= 1'b1; m_addr <= {tags[idx], idx, {OFF{1'b0}}};
                        n_wb <= n_wb + 1; state <= S_WB;
                    end else begin
                        m_we <= 1'b0; m_addr <= {tag, idx, {OFF{1'b0}}};
                        state <= S_FILL;
                    end
                end
            end
            S_WB: if (m_done) begin                              // victim written
                dirty[idx] <= 1'b0;
                m_we <= 1'b0; m_addr <= {tag, idx, {OFF{1'b0}}};   // now fetch ours
                state <= S_FILL;
            end
            S_FILL: if (m_done) begin
                lines[idx] <= m_rdata; tags[idx] <= tag;
                valid[idx] <= 1'b1;   dirty[idx] <= 1'b0;
                m_req <= 1'b0; state <= S_IDLE;
            end
            S_CLEAN: if (!cwb) begin
                if (ci == LINES) begin cleaned <= 1'b1; state <= S_IDLE; end
                else if (valid[ci[IDX-1:0]] & dirty[ci[IDX-1:0]]) begin
                    m_req <= 1'b1; m_we <= 1'b1; cwb <= 1'b1; n_wb <= n_wb + 1;
                    m_addr <= {tags[ci[IDX-1:0]], ci[IDX-1:0], {OFF{1'b0}}};
                end else ci <= ci + 1'b1;
            end else if (m_done) begin
                dirty[ci[IDX-1:0]] <= 1'b0;
                m_req <= 1'b0; m_we <= 1'b0; cwb <= 1'b0; ci <= ci + 1'b1;
            end
          endcase
        end
    end
endmodule

`default_nettype wire
