// =====================================================================
// plic.v  -  Platform-Level Interrupt Controller (compact, M-mode/1 hart)
// ---------------------------------------------------------------------
// Multiplexes SOURCES interrupt lines into a single machine-external
// interrupt (meip -> cpu ext_irq), the RISC-V standard way:
//
//   * priority   : each source has a priority (0 = never interrupt).
//   * pending    : a gateway latches an asserted source into a pending bit.
//   * enable     : a per-context (here: one M-mode context) enable bitmap.
//   * threshold  : only sources with priority > threshold are presented.
//   * claim      : reading the claim register returns the id of the highest-
//                  priority pending+enabled source and atomically clears its
//                  pending bit (lowest id wins ties). Reading 0 = none.
//   * complete   : writing that id back tells the gateway servicing is done,
//                  so the source may interrupt again.
//
// Gateway (works for level or pulsed sources): a source latches pending when
// it is asserted and not already pending or in-service. Claim clears pending
// and marks the source in-service; complete clears in-service. If a level
// source is still asserted after complete, it re-pends -- exactly once per
// service cycle, never re-claimed while in flight.
//
// Register map (byte offsets within the PLIC's address window):
//   0x0000 + 4*i : priority of source i        (RW)
//   0x1000       : pending bitmap (bit i)       (RO)
//   0x2000       : enable  bitmap (bit i)       (RW)
//   0x3000       : priority threshold           (RW)
//   0x3004       : claim (R) / complete (W)
// A real PLIC spreads these across a 64 MB region (threshold/claim at
// 0x20_0000+); this keeps the same semantics in a compact window.
// =====================================================================
`default_nettype none

module plic #(
    parameter SOURCES = 4,           // interrupt sources, ids 1..SOURCES
    parameter PW      = 3            // priority/threshold width (0..2^PW-1)
) (
    input  wire        clk,
    input  wire        rst,
    // simple MMIO slave
    input  wire        sel,
    input  wire        we,
    input  wire [15:0] addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    // raw interrupt source lines (level or pulse), id i on bit i
    input  wire [SOURCES:1] src,
    // to the hart
    output wire        meip
);
    integer k;
    reg [PW-1:0] prio   [1:SOURCES];
    reg          en     [1:SOURCES];
    reg          pend   [1:SOURCES];      // gateway: pending
    reg          infl   [1:SOURCES];      // gateway: in-service (claimed)
    reg [PW-1:0] thresh;

    // ---- arbitration: highest priority pending+enabled above threshold ----
    reg [31:0]   claim_id;
    reg [PW-1:0] claim_pri;
    reg          any_elig;
    always @(*) begin
        claim_id = 32'd0; claim_pri = {PW{1'b0}}; any_elig = 1'b0;
        for (k = 1; k <= SOURCES; k = k + 1) begin
            if (pend[k] && en[k] && (prio[k] > thresh)) begin
                any_elig = 1'b1;
                if (prio[k] > claim_pri) begin       // strict '>' => lowest id wins ties
                    claim_pri = prio[k];
                    claim_id  = k;
                end
            end
        end
    end
    assign meip = any_elig;

    // ---- address decode ----
    wire is_prio   = sel & (addr[15:12] == 4'h0);
    wire is_pend   = sel & (addr[15:12] == 4'h1);
    wire is_en     = sel & (addr[15:12] == 4'h2);
    wire is_thresh = sel & (addr[15:12] == 4'h3) & ~addr[2];
    wire is_claim  = sel & (addr[15:12] == 4'h3) &  addr[2];
    wire [3:0] pidx = addr[5:2];          // source index for the priority array

    // ---- claim read must take effect exactly once per load access ----
    reg        claim_d;
    wire       claim_rd = is_claim & ~we;
    wire       claim_stb = claim_rd & ~claim_d;     // 1-cycle pulse
    reg [31:0] claimed_reg;

    // ---- reads ----
    always @(*) begin
        rdata = 32'd0;
        if (is_prio) begin
            rdata = (pidx >= 1 && pidx <= SOURCES) ? {{(32-PW){1'b0}}, prio[pidx]} : 32'd0;
        end else if (is_pend) begin
            for (k = 1; k <= SOURCES; k = k + 1) rdata[k] = pend[k];
        end else if (is_en) begin
            for (k = 1; k <= SOURCES; k = k + 1) rdata[k] = en[k];
        end else if (is_thresh) begin
            rdata = {{(32-PW){1'b0}}, thresh};
        end else if (is_claim) begin
            rdata = claim_stb ? claim_id : claimed_reg;  // stable across the 2-cycle load
        end
    end

    // ---- state update ----
    always @(posedge clk) begin
        if (rst) begin
            for (k = 1; k <= SOURCES; k = k + 1) begin
                prio[k] <= {PW{1'b0}}; en[k] <= 1'b0; pend[k] <= 1'b0; infl[k] <= 1'b0;
            end
            thresh <= {PW{1'b0}}; claim_d <= 1'b0; claimed_reg <= 32'd0;
        end else begin
            claim_d <= claim_rd;

            // register writes
            if (is_prio & we && pidx >= 1 && pidx <= SOURCES) prio[pidx] <= wdata[PW-1:0];
            if (is_en   & we) for (k = 1; k <= SOURCES; k = k + 1) en[k] <= wdata[k];
            if (is_thresh & we) thresh <= wdata[PW-1:0];

            // complete: writing an id to the claim register ends its service
            if (is_claim & we && wdata >= 1 && wdata <= SOURCES) infl[wdata] <= 1'b0;

            // claim: take the arbitrated id, clear its pending, mark in-service
            if (claim_stb && claim_id != 0) begin
                claimed_reg     <= claim_id;
                infl[claim_id]  <= 1'b1;
                pend[claim_id]  <= 1'b0;
            end else if (claim_stb) begin
                claimed_reg     <= 32'd0;
            end

            // gateway: latch pending for asserted sources not already in flight
            for (k = 1; k <= SOURCES; k = k + 1) begin
                if (!(claim_stb && claim_id == k) && !pend[k] && !infl[k] && src[k])
                    pend[k] <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
