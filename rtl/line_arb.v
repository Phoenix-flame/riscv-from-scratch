// =====================================================================
// line_arb.v  -  two cache refill ports onto one line memory
// ---------------------------------------------------------------------
// With one memory behind both caches (Step 51), the I-cache's refills
// and the D-cache's refills and write-backs have to take turns on it.
// All three speak mem_slow's line protocol: hold `req` (+ we / addr /
// wdata) until a one-cycle `done`. This grants the port to one requester
// at a time and holds it until that transaction's `done`; the D side
// wins a tie, because a D-cache miss freezes the whole pipeline while an
// I-cache miss only starves IF.
//
// A grant is never changed in the cycle `done` arrives, and the memory
// never starts in a `done` cycle (the same rule mem_slow keeps), so a
// cache that changes its request at that edge -- the D-cache goes from a
// write-back straight to the refill -- is seen with its new request.
// Only bursts pass through: both caches always move whole lines.
// =====================================================================
`default_nettype none

module line_arb #(
    parameter LW = 256                     // line width in bits
) (
    input  wire          clk,
    input  wire          rst,
    // ---- D side (priority) ----
    input  wire          d_req,
    input  wire          d_we,
    input  wire [31:0]   d_addr,
    input  wire [LW-1:0] d_wdata,
    output wire          d_done,
    // ---- I side (reads only) ----
    input  wire          i_req,
    input  wire [31:0]   i_addr,
    output wire          i_done,          // (both sides read the memory's rdata)
    // ---- to memory ----
    output wire          m_req,
    output wire          m_we,
    output wire [31:0]   m_addr,
    output wire [LW-1:0] m_wdata,
    input  wire          m_done
);
    localparam NONE = 2'd0, D = 2'd1, I = 2'd2;
    reg [1:0] owner;

    always @(posedge clk)
        if (rst)                       owner <= NONE;
        else if (m_done)               owner <= NONE;
        else if (owner == NONE)        owner <= d_req ? D : i_req ? I : NONE;

    assign m_req   = (owner == D) ? d_req : (owner == I) ? i_req : 1'b0;
    assign m_we    = (owner == D) & d_we;
    assign m_addr  = (owner == I) ? i_addr : d_addr;
    assign m_wdata = d_wdata;
    assign d_done  = m_done & (owner == D);
    assign i_done  = m_done & (owner == I);
endmodule

`default_nettype wire
