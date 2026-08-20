// =====================================================================
// s6_csr.v  -  Machine-mode CSR file, trap unit and counters
// ---------------------------------------------------------------------
// Everything the privileged spec asks of an M(+U)-mode RV32 hart that has
// no MMU and no PMP:
//
//   0x300 mstatus   MIE / MPIE / MPP        0x310 mstatush  (0)
//   0x301 misa      MXL=32, the enabled extension letters (read-only here)
//   0x304 mie       MSIE / MTIE / MEIE      0x344 mip  (read-only: CLINT/PLIC)
//   0x305 mtvec     direct AND vectored     0x306 mcounteren
//   0x320 mcountinhibit                     0x340 mscratch
//   0x341 mepc      0x342 mcause  0x343 mtval
//   0xB00/0xB80 mcycle/h   0xB02/0xB82 minstret/h
//   0xC00/0xC01/0xC02 (+h) cycle / time / instret  -- U-mode shadows,
//                     readable only through mcounteren (Zicntr)
//   0xF11..0xF14 mvendorid / marchid / mimpid / mhartid
//
// `time` is not a counter we own: it is wired straight to the CLINT's
// 64-bit mtime, which is what the spec actually requires (a real-time
// counter, not a cycle counter).
//
// Trap entry saves pc -> mepc, cause -> mcause, the faulting address or
// instruction -> mtval, pushes MIE into MPIE and records the interrupted
// privilege in MPP. `mret` pops all three back. With mtvec in vectored
// mode interrupts land at base + 4*cause and exceptions still at base.
//
// Interrupt priority is the spec's: external > software > timer.
// =====================================================================
`default_nettype none

module s6_csr #(
    parameter [31:0] HART_ID  = 32'd0,
    parameter [31:0] MISA_VAL = 32'h4000_0100,   // filled in by the core
    parameter        ENABLE_U = 1,
    parameter        ENABLE_C = 1
) (
    input  wire        clk,
    input  wire        rst,

    // ---- CSR instruction port ----
    input  wire [11:0] addr,
    input  wire [2:0]  f3,          // 001 RW 010 RS 011 RC (+1xx: uimm forms)
    input  wire [31:0] wsrc,        // rs1 value, or the zero-extended uimm
    input  wire        access,      // "this instruction is a CSR op" (decode)
    input  wire        will_write,  // ... and it will modify the CSR
    input  wire        we,          // ... and it is committing now
    output reg  [31:0] rdata,
    output wire        illegal,

    // ---- trap port ----
    input  wire        trap_take,
    input  wire [31:0] trap_pc,
    input  wire [31:0] trap_cause,
    input  wire [31:0] trap_tval,
    input  wire        mret,
    output wire [31:0] trap_target,
    output wire [31:0] mepc_out,
    output wire [1:0]  priv,

    // ---- interrupts ----
    input  wire        timer_irq,
    input  wire        soft_irq,
    input  wire        ext_irq,
    output wire        irq_pending,   // ... and globally enabled: take it
    output wire        irq_any,       // ... enabled in mie only: wakes WFI
    output wire [31:0] irq_cause,

    // ---- counters ----
    input  wire        retire,
    input  wire [63:0] mtime
);
    localparam PRIV_M = 2'b11, PRIV_U = 2'b00;

    // ---- architectural state ----
    reg        st_mie, st_mpie;
    reg [1:0]  st_mpp;
    reg [1:0]  priv_r;
    reg        ie_msie, ie_mtie, ie_meie;
    reg [29:0] tvec_base;
    reg        tvec_vec;
    reg [31:0] mscratch_r, mepc_r, mcause_r, mtval_r;
    reg [2:0]  mcounteren_r;      // bit0 CY, bit1 TM, bit2 IR
    reg [2:0]  mcountinhibit_r;
    reg [63:0] mcycle_r, minstret_r;

    assign priv     = priv_r;
    assign mepc_out = mepc_r;

    // ---- pending interrupts -------------------------------------------
    wire [31:0] mip_val = {20'b0, ext_irq, 3'b0, timer_irq, 3'b0, soft_irq, 3'b0};
    wire [31:0] mie_val = {20'b0, ie_meie, 3'b0, ie_mtie, 3'b0, ie_msie, 3'b0};
    wire [31:0] pend    = mip_val & mie_val;

    assign irq_any     = |pend;
    // M-mode gates on mstatus.MIE; anything below M always takes M interrupts
    assign irq_pending = irq_any & ((priv_r != PRIV_M) | st_mie);
    assign irq_cause   = pend[11] ? 32'h8000_000B :      // machine external
                         pend[3]  ? 32'h8000_0003 :      // machine software
                         pend[7]  ? 32'h8000_0007 :      // machine timer
                                    32'h0000_0000;

    // ---- trap vector ---------------------------------------------------
    wire [31:0] tvec_bse = {tvec_base, 2'b00};
    assign trap_target = (tvec_vec & trap_cause[31])
                       ? (tvec_bse + {24'b0, trap_cause[5:0], 2'b00})
                       : tvec_bse;

    // ---- legality ------------------------------------------------------
    // Bits [11:10] == 11 marks a read-only CSR; [9:8] is the lowest
    // privilege that may touch it.
    reg  known;
    reg  is_counter_u;            // needs the matching mcounteren bit in U
    reg  counter_ok;
    always @(*) begin
        known        = 1'b1;
        is_counter_u = 1'b0;
        counter_ok   = 1'b1;
        case (addr)
            12'h300, 12'h301, 12'h304, 12'h305, 12'h306, 12'h310, 12'h320,
            12'h340, 12'h341, 12'h342, 12'h343, 12'h344,
            12'hB00, 12'hB02, 12'hB80, 12'hB82,
            12'hF11, 12'hF12, 12'hF13, 12'hF14: ;
            12'hC00, 12'hC80: begin is_counter_u = 1'b1; counter_ok = mcounteren_r[0]; end
            12'hC01, 12'hC81: begin is_counter_u = 1'b1; counter_ok = mcounteren_r[1]; end
            12'hC02, 12'hC82: begin is_counter_u = 1'b1; counter_ok = mcounteren_r[2]; end
            default: known = 1'b0;
        endcase
    end

    wire read_only  = (addr[11:10] == 2'b11);
    wire priv_short = (priv_r < addr[9:8]);          // not privileged enough
    wire cnt_block  = is_counter_u & (priv_r != PRIV_M) & ~counter_ok;
    assign illegal  = access & (~known | (will_write & read_only) |
                                priv_short | cnt_block);

    // ---- the value being written ---------------------------------------
    wire [31:0] wdata = (f3[1:0] == 2'b01) ? wsrc            :   // CSRRW(I)
                        (f3[1:0] == 2'b10) ? (rdata |  wsrc) :   // CSRRS(I)
                                             (rdata & ~wsrc);    // CSRRC(I)
    wire wr = we & ~illegal;
    wire hit_mepc_mask = ENABLE_C ? 1'b0 : 1'b1;                 // IALIGN 16 vs 32

    always @(posedge clk) begin
        if (rst) begin
            st_mie <= 1'b0; st_mpie <= 1'b0; st_mpp <= PRIV_M;
            priv_r <= PRIV_M;
            ie_msie <= 1'b0; ie_mtie <= 1'b0; ie_meie <= 1'b0;
            tvec_base <= 30'd0; tvec_vec <= 1'b0;
            mscratch_r <= 32'd0; mepc_r <= 32'd0;
            mcause_r <= 32'd0; mtval_r <= 32'd0;
            mcounteren_r <= 3'd0; mcountinhibit_r <= 3'd0;
            mcycle_r <= 64'd0; minstret_r <= 64'd0;
        end else begin
            // ---- free-running counters (Zicntr) ----
            if (!mcountinhibit_r[0]) mcycle_r   <= mcycle_r + 64'd1;
            if (!mcountinhibit_r[2] && retire) minstret_r <= minstret_r + 64'd1;

            // ---- explicit CSR writes ----
            if (wr) case (addr)
                12'h300: begin st_mie <= wdata[3]; st_mpie <= wdata[7];
                               st_mpp <= (ENABLE_U && wdata[12:11] == PRIV_U)
                                         ? PRIV_U : PRIV_M; end
                12'h304: begin ie_msie <= wdata[3]; ie_mtie <= wdata[7];
                               ie_meie <= wdata[11]; end
                12'h305: begin tvec_base <= wdata[31:2]; tvec_vec <= wdata[0]; end
                12'h306: mcounteren_r    <= wdata[2:0];
                12'h320: mcountinhibit_r <= wdata[2:0];
                12'h340: mscratch_r <= wdata;
                12'h341: mepc_r     <= {wdata[31:2], wdata[1] & ~hit_mepc_mask, 1'b0};
                12'h342: mcause_r   <= wdata;
                12'h343: mtval_r    <= wdata;
                12'hB00: mcycle_r[31:0]    <= wdata;
                12'hB80: mcycle_r[63:32]   <= wdata;
                12'hB02: minstret_r[31:0]  <= wdata;
                12'hB82: minstret_r[63:32] <= wdata;
                default: ;
            endcase

            // ---- trap entry wins over a CSR write in the same cycle ----
            if (trap_take) begin
                mepc_r   <= trap_pc;
                mcause_r <= trap_cause;
                mtval_r  <= trap_tval;
                st_mpie  <= st_mie;
                st_mie   <= 1'b0;
                st_mpp   <= priv_r;
                priv_r   <= PRIV_M;
            end else if (mret) begin
                st_mie  <= st_mpie;
                st_mpie <= 1'b1;
                priv_r  <= st_mpp;
                st_mpp  <= ENABLE_U ? PRIV_U : PRIV_M;
            end
        end
    end

    // ---- read mux --------------------------------------------------------
    wire [31:0] mstatus_val = {19'b0, 2'b00, st_mpp, 3'b0, st_mpie, 3'b0, st_mie, 3'b0};

    always @(*) begin
        case (addr)
            12'h300: rdata = mstatus_val;
            12'h301: rdata = MISA_VAL;
            12'h304: rdata = mie_val;
            12'h305: rdata = {tvec_base, 1'b0, tvec_vec};
            12'h306: rdata = {29'b0, mcounteren_r};
            12'h310: rdata = 32'd0;                       // mstatush
            12'h320: rdata = {29'b0, mcountinhibit_r};
            12'h340: rdata = mscratch_r;
            12'h341: rdata = mepc_r;
            12'h342: rdata = mcause_r;
            12'h343: rdata = mtval_r;
            12'h344: rdata = mip_val;
            12'hB00, 12'hC00: rdata = mcycle_r[31:0];
            12'hB80, 12'hC80: rdata = mcycle_r[63:32];
            12'hB02, 12'hC02: rdata = minstret_r[31:0];
            12'hB82, 12'hC82: rdata = minstret_r[63:32];
            12'hC01: rdata = mtime[31:0];
            12'hC81: rdata = mtime[63:32];
            12'hF14: rdata = HART_ID;
            default: rdata = 32'd0;    // mvendorid/marchid/mimpid are 0
        endcase
    end
endmodule

`default_nettype wire
