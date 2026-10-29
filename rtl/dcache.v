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

// =====================================================================
// dcache_b  -  the same cache, its lines and tags in block RAM (Step 59)
// ---------------------------------------------------------------------
// Block RAM reads on a clock edge: the address goes in at the edge, the
// line comes out during the next cycle. dcache reads its arrays in the
// cycle of the access; this one reads them a cycle earlier, and must know
// that what it read is what is asked for -- without comparing against the
// D-port's address, which comes late (MEM's, or the walker's, through a
// mux). So it reads either
//   * the hint, when the core says (`hint_ok`) that the next cycle's
//     request, if any, is at `hint` (the load / store in EX moving to MEM:
//     the physical address XLATE_2C registered), or
//   * the request in front of it, when that is not finishing this cycle
//     (the core holds a request until `ready`, so it is there next cycle),
// and otherwise knows nothing, and reads the request when it comes: one
// cycle more (a walk, an AMO's second half). The tag compare is against
// the registered tag of the address read. A simulation-only check holds
// the core to `hint_ok`.
//
//   * a store hit writes the merged line at the edge; a read of the same
//     line at that edge sees it without the stored word, so that word is
//     kept (wword_q, at wsel_q) and put back in (byp_q)
//   * a fill writes line and tag at the edge, and the read after it is
//     redone (stale_q)
//   * valid and dirty live beside each tag, {valid, dirty, tag}, in the
//     tag block RAM: a fill writes {1, 0, tag}, a store hit {1, 1, tag},
//     clean's write-back {1, 0, tag}; a store's own read of its entry (at
//     the same edge) gets dirty from the bypass. After reset S_INIT clears
//     the entries, one an edge, before the first access
//   * the miss address, and clean's counter, load in every idle cycle: no
//     enable waits for the hit
//   * the victim and the lines `clean` writes back go through wbuf, which
//     follows the line read until a write-back starts
//   * `clean` reads one line, then decides: two cycles a line
// =====================================================================
`default_nettype none

module dcache_b #(
    parameter LINES      = 512,
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
    input  wire [31:0]              hint,        // the address presented next cycle, if hint_ok
    input  wire                     hint_ok,     // ... a promise: the next request, if any, is at hint
    input  wire                     clean,
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
    localparam TE  = TAG + 2;                    // a tag entry: {valid, dirty, tag}
    localparam LW  = 32 * LINE_WORDS;
    localparam S_IDLE=3'd0, S_WB=3'd1, S_FILL=3'd2, S_CLEAN=3'd3, S_INIT=3'd4;

    reg [LW-1:0]    lines [0:LINES-1];           // block RAM
    reg [TE-1:0]    tags  [0:LINES-1];           // block RAM

    wire [IDX-1:0] idx  = addr[OFF+IDX-1:OFF];
    wire [TAG-1:0] tag  = addr[31:OFF+IDX];
    wire [OFF-3:0] word = addr[OFF-1:2];

    reg  [2:0]     state;
    reg  [IDX:0]   ci;                           // clean / init: the line being looked at
    reg            cwb, cleaned;
    reg  [LW-1:0]  wbuf;                         // the line being written back

    // ---- the registered read ----
    reg  [IDX-1:0] ridx_q;                       // the index read at the last edge
    reg  [LW-1:0]  line_q;
    reg  [TE-1:0]  tent_q;
    reg  [31:0]    wword_q;
    reg  [OFF-3:0] wsel_q;
    reg            stale_q, byp_q;
    reg            lk_q;                         // the last read was for the request now in front
    reg  [TAG-1:0] rtag_q;                       // ... and this is its tag
    reg  [OFF-3:0] rword_q;                      // ... and word: the select from a register (Step 62)
    // the line as it is now: the read, with the word stored at that edge
    wire [LW-1:0]  line_e  = byp_q ? (line_q & ~({{(LW-32){1'b0}}, 32'hFFFF_FFFF} << (32*wsel_q)))
                                   | ({{(LW-32){1'b0}}, wword_q} << (32*wsel_q))
                                   : line_q;
    wire           valid_q = tent_q[TE-1];
    wire           dirty_q = tent_q[TE-2] | byp_q;   // a store at that edge made it dirty
    wire [TAG-1:0] tag_q   = tent_q[TAG-1:0];
    wire           look_ok = lk_q & ~stale_q;   // that read is this request's
    wire           hit     = look_ok & valid_q & (tag_q == rtag_q);
    wire           vdirty  = valid_q & dirty_q;      // the victim must go back
    assign ready      = req & hit & (state == S_IDLE);
    assign rdata      = line_e[32*rword_q +: 32];  // (= word whenever ready)
    assign m_wdata    = wbuf;
    assign clean_done = clean & cleaned;

    // the index to read at this edge: clean's / init's line; the hint, as
    // promised; else the request in front (a miss's line while it runs)
    wire           use_hint = (state == S_IDLE) & hint_ok;
    wire [IDX-1:0] ridx = (state == S_CLEAN || state == S_INIT) ? ci[IDX-1:0] :
                          use_hint                              ? hint[OFF+IDX-1:OFF] : idx;

    // write-hit merge
    wire [31:0] old_w = line_e[32*rword_q +: 32];
    wire [31:0] new_w = { we[3] ? wdata[31:24] : old_w[31:24],
                          we[2] ? wdata[23:16] : old_w[23:16],
                          we[1] ? wdata[15:8]  : old_w[15:8],
                          we[0] ? wdata[7:0]   : old_w[7:0] };
    wire [LW-1:0] merged = (line_e & ~({{(LW-32){1'b0}}, 32'hFFFF_FFFF} << (32*rword_q)))
                         | ({{(LW-32){1'b0}}, new_w} << (32*rword_q));
    wire          st_we   = (state == S_IDLE) & req & hit & (|we);   // at ridx_q (= idx)
    wire          fill_we = (state == S_FILL) & m_done;               // at ridx_q (read every edge of S_FILL)
    wire          line_we = st_we | fill_we;
    wire [LW-1:0] line_wd = fill_we ? m_rdata : merged;
    // the tag entries' one write port
    wire          init_we = (state == S_INIT) & (ci != LINES);
    wire          cln_we  = (state == S_CLEAN) & cwb & m_done;      // ci's entry, now clean
    wire          tag_we  = init_we | cln_we | fill_we | st_we;
    wire [IDX-1:0] tag_wa = (init_we | cln_we) ? ci[IDX-1:0] : ridx_q;
    wire [TE-1:0]  tag_wd = init_we ? {TE{1'b0}} :
                            cln_we  ? {2'b10, tag_q} : {1'b1, st_we, rtag_q};

    // the arrays: one write port, one read port, read-first
    always @(posedge clk) begin
        if (line_we) lines[ridx_q] <= line_wd;
        line_q <= lines[ridx];
    end
    always @(posedge clk) begin
        if (tag_we) tags[tag_wa] <= tag_wd;
        tent_q <= tags[ridx];
    end
    always @(posedge clk) begin
        ridx_q  <= ridx;
        rtag_q  <= use_hint ? hint[31:OFF+IDX] : tag;
        rword_q <= use_hint ? hint[OFF-1:2] : word;
        // the read is the request's: the hint as promised; or the request
        // itself, still waiting (a miss included); never in clean or init
        lk_q    <= !rst && (use_hint || ((state == S_IDLE) ? (req & ~ready) :
                                         (state == S_WB || state == S_FILL)));
        stale_q <= rst | (fill_we & (ridx_q == ridx));
        byp_q   <= st_we & (ridx_q == ridx);
        wword_q <= new_w; wsel_q <= rword_q;
    end

    reg [31:0] n_hit, n_miss, n_wb;              // statistics

    // wbuf takes the line read every cycle, and holds while a write-back
    // runs: at the edge one starts it has the victim (an enable that never
    // waits for the miss to be decided)
    always @(posedge clk)
        if (!(state == S_WB || (state == S_CLEAN && cwb))) wbuf <= line_e;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_INIT; m_req <= 1'b0; m_we <= 1'b0; m_addr <= 32'd0;
            n_hit <= 0; n_miss <= 0; n_wb <= 0; ci <= 0; cwb <= 1'b0; cleaned <= 1'b0;
        end else begin
          if (!clean) cleaned <= 1'b0;
          case (state)
            S_INIT: if (ci == LINES) state <= S_IDLE; else ci <= ci + 1'b1;
            S_IDLE: begin
              ci <= 0; cwb <= 1'b0;
              m_addr <= vdirty ? {tag_q, ridx_q, {OFF{1'b0}}} : {rtag_q, ridx_q, {OFF{1'b0}}};
              if (clean && !cleaned && !req) begin
                state <= S_CLEAN;
              end else if (req && look_ok) begin
                if (hit) begin
                    n_hit <= n_hit + 1;
                end else begin
                    n_miss <= n_miss + 1;
                    m_req  <= 1'b1;
                    if (vdirty) begin                            // evict first
                        m_we <= 1'b1; n_wb <= n_wb + 1; state <= S_WB;
                    end else begin
                        m_we <= 1'b0; state <= S_FILL;
                    end
                end
              end
            end
            S_WB: if (m_done) begin                           // the fill rewrites the entry
                m_we <= 1'b0; m_addr <= {rtag_q, ridx_q, {OFF{1'b0}}};
                state <= S_FILL;
            end
            S_FILL: if (m_done) begin                         // line + entry: fill_we
                m_req <= 1'b0; state <= S_IDLE;
            end
            S_CLEAN: if (!cwb) begin
                if (ci == LINES) begin cleaned <= 1'b1; state <= S_IDLE; end
                else if (ridx_q == ci[IDX-1:0] && !stale_q) begin   // line ci is out
                    if (vdirty) begin
                        m_req <= 1'b1; m_we <= 1'b1; cwb <= 1'b1; n_wb <= n_wb + 1;
                        m_addr <= {tag_q, ci[IDX-1:0], {OFF{1'b0}}};
                    end else ci <= ci + 1'b1;
                end
            end else if (m_done) begin                        // entry now clean: cln_we
                m_req <= 1'b0; m_we <= 1'b0; cwb <= 1'b0; ci <= ci + 1'b1;
            end
            default: state <= S_IDLE;
          endcase
        end
    end
`ifndef SYNTHESIS
    // simulation only: a read taken as the request's must be for its line
    always @(posedge clk)
        if (!rst && req && state == S_IDLE && look_ok && (ridx_q != idx || rtag_q != tag || rword_q != word)) begin
            $display("DCACHE_B: the read at %0d/%h is not the request's (%h): a broken hint_ok", ridx_q, rtag_q, addr);
            $finish;
        end
`endif
endmodule

`default_nettype wire
