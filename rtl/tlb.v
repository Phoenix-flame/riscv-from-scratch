// =====================================================================
// tlb.v  -  Small fully-associative Sv32 TLB (one instance per side)
// ---------------------------------------------------------------------
// Caches completed page-table walks so that most translated accesses
// skip the multi-cycle walk. Each entry remembers one leaf PTE:
//
//   valid | super | VPN tag (20) | PPN (22) | U X W R
//
// A 4 KiB entry matches all 20 VPN bits; a 4 MiB superpage entry matches
// only VPN[1] (the top 10) and passes VA[21:0] straight through.
//
//   lookup : combinational -- hit / pa / permission bits for `va`
//   fill   : write one entry (round-robin victim) after a walk
//   flush  : sfence.vma -- all entries, or only those mapping `flush_va`
//
// The permission bits are returned, not checked: the core decides what
// the access needs (X for fetch, R for load, W for store). ASIDs are not
// tagged, so software must sfence.vma after changing satp.
//
// ENABLE=0 builds a TLB that never hits (and never fills): every access
// walks, which is how the testbench measures what the TLB buys.
// =====================================================================
`default_nettype none

module tlb #(
    parameter ENTRIES = 4,
    parameter ENABLE  = 1,
    parameter FAST_FILL = 0     // 1: the replacement pointer moves on every fill, flush or not (Step 59)
) (
    input  wire        clk,
    input  wire        rst,

    // ---- lookup ----
    input  wire [31:0] va,
    output reg         hit,
    output reg  [31:0] pa,
    output reg  [3:0]  perm,        // {U, X, W, R}

    // ---- fill (after a successful walk to a valid leaf) ----
    input  wire        fill,
    input  wire [31:0] fill_va,
    input  wire [21:0] fill_ppn,    // leaf pte[31:10]
    input  wire        fill_super,  // leaf found at level 1 (4 MiB)
    input  wire [3:0]  fill_perm,   // {U, X, W, R}

    // ---- sfence.vma ----
    input  wire        flush_all,
    input  wire        flush_one,
    input  wire [31:0] flush_va
);
    localparam IW = (ENTRIES > 1) ? $clog2(ENTRIES) : 1;

    // entry i lives in slice i of each packed vector (packed rather than
    // arrays so the combinational lookup reads plain vectors)
    reg [ENTRIES-1:0]    v, sp;
    reg [20*ENTRIES-1:0] tag;
    reg [22*ENTRIES-1:0] ppn;
    reg [4*ENTRIES-1:0]  prm;
    reg [IW-1:0] victim;            // round-robin replacement pointer

    // does entry i translate virtual page `vpn`?
    function match;
        input        valid, is_super;
        input [19:0] etag, vpn;
        match = valid & (is_super ? (etag[19:10] == vpn[19:10]) : (etag == vpn));
    endfunction

    // ---- lookup (a fill never creates a duplicate, so at most one hits) ----
    integer i;
    always @(*) begin
        hit = 1'b0; pa = va; perm = 4'b0;
        for (i = 0; i < ENTRIES; i = i + 1)
            if (ENABLE && match(v[i], sp[i], tag[20*i +: 20], va[31:12])) begin
                hit  = 1'b1;
                perm = prm[4*i +: 4];
                pa   = sp[i] ? {ppn[22*i+10 +: 12], va[21:0]}   // 4 MiB superpage
                             : {ppn[22*i    +: 20], va[11:0]};  // 4 KiB page
            end
    end

    // ---- fill / flush ----
    // An entry's contents are only ever read through its valid bit, so a
    // fill writes them whatever else happens that cycle: only v (and, unless
    // FAST_FILL, the pointer) waits for a flush -- which arrives late, from
    // sfence.vma in EX (Step 59: the fill's enable no longer does)
    integer j;
    always @(posedge clk) begin
        if (rst || flush_all) begin
            v <= {ENTRIES{1'b0}};
        end else begin
            if (flush_one)
                for (j = 0; j < ENTRIES; j = j + 1)
                    if (match(v[j], sp[j], tag[20*j +: 20], flush_va[31:12])) v[j] <= 1'b0;
            if (fill && ENABLE) v[victim] <= 1'b1;
        end
        if (fill && ENABLE) begin
            sp[victim]  <= fill_super;
            tag[20*victim +: 20] <= fill_va[31:12];
            ppn[22*victim +: 22] <= fill_ppn;
            prm[4*victim  +: 4]  <= fill_perm;
        end
        if (rst)
            victim <= {IW{1'b0}};
        else if (fill && ENABLE && (FAST_FILL != 0 || !flush_all))
            victim <= (victim == ENTRIES-1) ? {IW{1'b0}} : victim + 1'b1;
    end
endmodule

`default_nettype wire
