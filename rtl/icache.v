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
// dirty state. `inval` (Step 51, for FENCE.I on a memory shared with the
// D-side) clears every line in one cycle; a refill already in flight then
// completes but is not installed, since it may have read memory before
// the D-cache's write-back reached it.
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
    input  wire                     inval,       // drop every line (FENCE.I)
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

    reg        filling, drop;
    reg [31:0] miss_addr;
    assign m_addr = {miss_addr[31:OFF], {OFF{1'b0}}};
    assign rdata  = line[32*word +: 32];
    assign ready  = req & hit & ~filling;

    // statistics (simulation visibility; harmless in hardware)
    reg [31:0] n_hit, n_miss;

    always @(posedge clk) begin
        if (rst) begin
            valid <= {LINES{1'b0}}; filling <= 1'b0; m_req <= 1'b0; drop <= 1'b0;
            miss_addr <= 32'd0; n_hit <= 0; n_miss <= 0;
        end else if (inval) begin
            valid <= {LINES{1'b0}};
            if (filling) drop <= ~m_done;
            if (filling & m_done) begin m_req <= 1'b0; filling <= 1'b0; end
        end else if (!filling) begin
            if (req & hit) n_hit <= n_hit + 1;
            if (req & ~hit) begin
                miss_addr <= addr; m_req <= 1'b1; filling <= 1'b1; n_miss <= n_miss + 1;
            end
        end else if (m_done) begin
            lines[miss_addr[OFF+IDX-1:OFF]] <= m_rdata;
            tags [miss_addr[OFF+IDX-1:OFF]] <= miss_addr[31:OFF+IDX];
            valid[miss_addr[OFF+IDX-1:OFF]] <= ~drop;
            m_req <= 1'b0; filling <= 1'b0; drop <= 1'b0;
        end
    end
endmodule

`default_nettype wire

// =====================================================================
// icache_b  -  the same cache, its lines and tags in block RAM (Step 59)
// ---------------------------------------------------------------------
// As dcache_b: the arrays are read at the edge before the fetch, at the
// address the core says comes next (`hint`: the PC register's next value,
// through the fetch page's registered translation). A fetch whose index
// was not the one read waits a cycle and is read again; a fill writes at
// an edge and the read after it is redone. Each tag entry carries its
// valid bit, {valid, tag}, so `inval` (FENCE.I) and reset clear the
// entries one an edge (`clearing`, LINES cycles) and answer no fetch
// meanwhile; an inval that lands during a fill lets the fill finish first.
// =====================================================================
`default_nettype none

module icache_b #(
    parameter LINES      = 512,
    parameter LINE_WORDS = 8
) (
    input  wire                     clk,
    input  wire                     rst,
    input  wire [31:0]              addr,
    input  wire                     req,
    output wire [31:0]              rdata,
    output wire                     ready,
    input  wire [31:0]              hint,        // the address likely fetched next cycle
    input  wire                     inval,
    output reg                      m_req,
    output wire [31:0]              m_addr,
    input  wire                     m_done,
    input  wire [32*LINE_WORDS-1:0] m_rdata
);
    localparam OFF = $clog2(LINE_WORDS) + 2;
    localparam IDX = $clog2(LINES);
    localparam TAG = 32 - OFF - IDX;
    localparam TE  = TAG + 1;                    // a tag entry: {valid, tag}
    localparam LW  = 32 * LINE_WORDS;

    reg [LW-1:0]    lines [0:LINES-1];           // block RAM
    reg [TE-1:0]    tags  [0:LINES-1];           // block RAM

    wire [IDX-1:0] idx  = addr[OFF+IDX-1:OFF];
    wire [TAG-1:0] tag  = addr[31:OFF+IDX];
    wire [OFF-3:0] word = addr[OFF-1:2];

    reg        filling, clearing, inv_pend;
    reg [IDX:0] ci;                              // clearing: the next entry
    reg [31:0] miss_addr;
    wire [IDX-1:0] midx = miss_addr[OFF+IDX-1:OFF];
    assign m_addr = {miss_addr[31:OFF], {OFF{1'b0}}};

    reg  [IDX-1:0] ridx_q;
    reg  [LW-1:0]  line_q;
    reg  [TE-1:0]  tent_q;
    reg            stale_q;
    wire           look_ok = (ridx_q == idx) & ~stale_q;
    wire           hit     = look_ok & tent_q[TE-1] & (tent_q[TAG-1:0] == tag);
    wire           busy    = filling | clearing | inv_pend;
    assign rdata = line_q[32*word +: 32];
    assign ready = req & hit & ~busy;

    wire [IDX-1:0] ridx    = clearing ? ci[IDX-1:0] : filling ? midx :
                             (req & ~look_ok) ? idx : hint[OFF+IDX-1:OFF];
    wire           fill_we = filling & m_done;
    wire           clr_we  = clearing & (ci != LINES);

    always @(posedge clk) begin
        if (fill_we) lines[midx] <= m_rdata;
        line_q <= lines[ridx];
    end
    always @(posedge clk) begin
        if (clr_we)       tags[ci[IDX-1:0]] <= {TE{1'b0}};
        else if (fill_we) tags[midx] <= {1'b1, miss_addr[31:OFF+IDX]};
        tent_q <= tags[ridx];
    end
    always @(posedge clk) begin
        ridx_q  <= ridx;
        stale_q <= rst | clearing | (fill_we & (midx == ridx));
    end

    reg [31:0] n_hit, n_miss;

    // the miss address follows the fetch until a fill starts (no enable
    // that waits for the hit)
    always @(posedge clk)
        if (rst) miss_addr <= 32'd0;
        else if (!filling) miss_addr <= addr;

    always @(posedge clk) begin
        if (rst) begin
            filling <= 1'b0; m_req <= 1'b0; clearing <= 1'b1; inv_pend <= 1'b0; ci <= 0;
            n_hit <= 0; n_miss <= 0;
        end else begin
            if (fill_we) begin m_req <= 1'b0; filling <= 1'b0; end
            if (inval) begin
                inv_pend <= 1'b1; clearing <= 1'b0;   // (a clear under way starts again)
            end else if (inv_pend && !filling) begin
                inv_pend <= 1'b0; clearing <= 1'b1; ci <= 0;
            end else if (clearing) begin
                if (ci == LINES) clearing <= 1'b0; else ci <= ci + 1'b1;
            end else if (!filling) begin
                if (req & hit) n_hit <= n_hit + 1;
                if (req & look_ok & ~hit) begin
                    m_req <= 1'b1; filling <= 1'b1; n_miss <= n_miss + 1;
                end
            end
        end
    end
endmodule

`default_nettype wire
