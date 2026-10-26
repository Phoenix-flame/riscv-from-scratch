// =====================================================================
// plic_sifive.v  -  the standard PLIC: sources -> per-CONTEXT interrupts
// ---------------------------------------------------------------------
// Step 33's plic.v drove one line, the hart's MEIP, from a compact 16 KiB
// map. A kernel needs the PLIC laid out the way the "sifive,plic-1.0.0" /
// "riscv,plic0" binding says, and needs a context of its own: a context is
// one (hart, privilege) target with its own enable bits, threshold and
// claim register. Here context 0 is hart 0 in M-mode (-> MEIP) and context
// 1 is hart 0 in S-mode (-> SEIP), as on QEMU virt and SiFive parts:
//
//   0x000000 + 4*i          priority of source i (1..SOURCES; 0 = never)
//   0x001000                pending bits, sources 0..31          (RO)
//   0x002000 + 0x80*c       enable bits of context c, sources 0..31
//   0x200000 + 0x1000*c     priority threshold of context c
//   0x200004 + 0x1000*c     claim (read) / complete (write) of context c
//
// The gateway is Step 33's, shared by all contexts: an asserted source
// becomes pending unless it is already pending or in service; a claim
// (from whichever context) clears pending and marks it in service; the
// complete ends the service, and a level source still asserted pends
// again. Each context sees the highest-priority source that is pending,
// enabled for it and above its threshold (lowest ID wins a tie).
//
// The claim's side effect fires on `sel & ~we`, which the SoC drives only
// for a real load (one D-port request), never on a bare address match.
// =====================================================================
`default_nettype none

module plic_sifive #(
    parameter SOURCES  = 31,         // IDs 1..SOURCES (at most 31)
    parameter CONTEXTS = 2,
    parameter PW       = 3           // priority / threshold bits
) (
    input  wire               clk,
    input  wire               rst,
    input  wire               sel,
    input  wire               we,
    input  wire [25:0]        addr,
    input  wire [31:0]        wdata,
    output reg  [31:0]        rdata,
    input  wire [SOURCES:1]   src,
    output wire [CONTEXTS-1:0] eip
);
    reg [PW-1:0]  prio [1:SOURCES];
    reg [SOURCES:1] pend, infl;
    reg [SOURCES:1] en   [0:CONTEXTS-1];
    reg [PW-1:0]  thresh [0:CONTEXTS-1];

    // ---- decode ----
    wire        a_prio  = (addr[25:12] == 14'd0);
    wire [9:0]  a_src   = addr[11:2];
    wire        a_pend  = (addr[25:12] == 14'd1) & (addr[11:2] == 10'd0);
    wire        a_en    = (addr[25:12] == 14'd2) & (addr[6:2] == 5'd0);
    wire [4:0]  a_enc   = addr[11:7];
    wire        a_ctx   = (addr[25:21] == 5'd1) & (addr[11:3] == 9'd0);
    wire [8:0]  a_c     = addr[20:12];
    wire        a_claim = a_ctx & addr[2];

    // ---- per-context arbitration ----
    reg [5:0]    best [0:CONTEXTS-1];
    reg [PW-1:0] bpri;
    integer c, k;
    always @(*)
        for (c = 0; c < CONTEXTS; c = c + 1) begin
            best[c] = 6'd0; bpri = {PW{1'b0}};
            for (k = 1; k <= SOURCES; k = k + 1)
                if (pend[k] && en[c][k] && prio[k] > thresh[c] && prio[k] > bpri) begin
                    best[c] = k; bpri = prio[k];
                end
        end
    genvar g;
    generate for (g = 0; g < CONTEXTS; g = g + 1) begin : g_eip
        assign eip[g] = (best[g] != 6'd0);
    end endgenerate

    wire       ctx_ok   = (a_c < CONTEXTS);
    wire       claim_rd = sel & ~we & a_claim & ctx_ok;
    wire [5:0] claimed  = ctx_ok ? best[a_c] : 6'd0;

    // ---- reads ----
    always @(*) begin
        rdata = 32'd0;
        if (a_prio && a_src >= 1 && a_src <= SOURCES) rdata = {{(32-PW){1'b0}}, prio[a_src]};
        else if (a_pend)                              rdata = {pend, 1'b0};
        else if (a_en && a_enc < CONTEXTS)            rdata = {en[a_enc], 1'b0};
        else if (a_ctx && ctx_ok && !addr[2])         rdata = {{(32-PW){1'b0}}, thresh[a_c]};
        else if (a_claim)                             rdata = {26'd0, claimed};
    end

    // ---- state ----
    always @(posedge clk) begin
        if (rst) begin
            for (k = 1; k <= SOURCES; k = k + 1) prio[k] <= {PW{1'b0}};
            for (c = 0; c < CONTEXTS; c = c + 1) begin en[c] <= {SOURCES{1'b0}}; thresh[c] <= {PW{1'b0}}; end
            pend <= {SOURCES{1'b0}}; infl <= {SOURCES{1'b0}};
        end else begin
            if (sel & we) begin
                if (a_prio && a_src >= 1 && a_src <= SOURCES) prio[a_src] <= wdata[PW-1:0];
                if (a_en && a_enc < CONTEXTS)                 en[a_enc] <= wdata[SOURCES:1];
                if (a_ctx && ctx_ok && !addr[2])              thresh[a_c] <= wdata[PW-1:0];
                if (a_claim && ctx_ok && wdata >= 1 && wdata <= SOURCES) infl[wdata] <= 1'b0;
            end
            for (k = 1; k <= SOURCES; k = k + 1)
                if (claim_rd && claimed == k) begin pend[k] <= 1'b0; infl[k] <= 1'b1; end
                else if (!pend[k] && !infl[k] && src[k]) pend[k] <= 1'b1;
        end
    end
endmodule

`default_nettype wire
