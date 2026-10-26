// =====================================================================
// csr_s.v  -  M + S-mode CSRs with trap delegation (medeleg/mideleg)
// ---------------------------------------------------------------------
// Extends the machine-mode trap controller with supervisor mode. A trap
// taken below M-mode is normally vectored to M; but if the matching bit is
// set in medeleg (for exceptions) or mideleg (for interrupts), the trap is
// instead delivered straight to an S-mode handler -- M-mode never runs.
// This is how a Unix-like kernel lives in S-mode and only the rare event
// (a genuine machine fault) reaches the M-mode monitor underneath it.
//
// Privilege encoding: 2'b11 = M, 2'b01 = S, 2'b00 = U.
//
// sstatus / sie / sip are restricted *views* of mstatus / mie / mip -- the
// same underlying bits, masked to those an S-mode kernel may see and set:
//   mstatus:  SIE=1  MIE=3  SPIE=5  MPIE=7  SPP=8  VS=10:9  MPP=12:11  SUM=18  MXR=19
//   (SUM / MXR only matter to a core with an MMU -- cpu_pipe_u, Step 44)
//   mie/mip:  SSI=1  MSI=3  STI=5   MTI=7   SEI=9  MEI=11
//
// Trap entry to S:  sepc<-pc  scause<-cause  SPIE<-SIE  SIE<-0  SPP<-(priv==S)
//                   priv<-S   pc<-stvec
// Trap entry to M:  (the existing M behavior)            pc<-mtvec
// sret:  SIE<-SPIE  SPIE<-1  priv<-SPP?S:U  SPP<-U   pc<-sepc
// mret:  MIE<-MPIE  MPIE<-1  priv<-MPP      MPP<-U   pc<-mepc
//
// Configurable (Step 45). HAS_S / HAS_U / HAS_SATP drop supervisor mode,
// user mode or the satp register: medeleg/mideleg then read 0 and ignore
// writes, MPP only ever holds a mode that exists (WARL), and satp reads 0.
// All default to 1 -- exactly the Step 39 behaviour.
// =====================================================================
`default_nettype none

module csr_s #(
    parameter HAS_S    = 1,
    parameter HAS_U    = 1,
    parameter HAS_SATP = 1,
    parameter HAS_V    = 1             // mstatus.VS writable (Step 47); else reads 0
) (
    input  wire        clk,
    input  wire        rst,

    input  wire [11:0] csr_addr,
    input  wire [2:0]  csr_funct3,
    input  wire [31:0] csr_wsrc,
    input  wire        csr_we,
    output reg  [31:0] csr_rdata,

    input  wire [31:0] pc,
    input  wire        timer_irq,
    input  wire        ext_irq,
    input  wire        s_ext_irq,       // SEIP from an interrupt controller (Step 50)
    input  wire        instr_is_mret,
    input  wire        instr_is_sret,
    input  wire        take_trap,       // core takes a trap this cycle
    input  wire [31:0] trap_cause,      // the cause being recorded
    input  wire [31:0] trap_val,        // mtval/stval value (badaddr/instr/0)

    output wire [31:0] trap_vector,     // where the trap jumps (mtvec or stvec)
    output wire [31:0] mret_target,     // mepc
    output wire [31:0] sret_target,     // sepc
    output wire        irq_pending,     // an interrupt is ready to fire
    output wire [31:0] irq_cause,       // its cause (bit31 set)
    output wire        deleg_now,       // the trap being taken routes to S
    output wire        status_sum,      // mstatus.SUM: S may touch U pages
    output wire        status_mxr,      // mstatus.MXR: loads may read X pages
    output wire [1:0]  status_vs,       // mstatus.VS: vector unit Off/Initial/Clean/Dirty
    input  wire        set_vs_dirty,    // vector state changed: VS <- Dirty (if not Off)
    output wire [1:0]  cur_priv,
    output wire [31:0] satp_out
);
    localparam MSTATUS=12'h300, MEDELEG=12'h302, MIDELEG=12'h303, MIE_A=12'h304,
               MTVEC=12'h305, MSCRATCH=12'h340, MEPC=12'h341, MCAUSE=12'h342,
               MTVAL=12'h343, MIP=12'h344,
               SSTATUS=12'h100, SIE_A=12'h104, STVEC=12'h105, SSCRATCH=12'h140,
               SEPC=12'h141, SCAUSE=12'h142, STVAL=12'h143, SIP=12'h144,
               SATP=12'h180;
    localparam PRIV_M=2'b11, PRIV_S=2'b01, PRIV_U=2'b00;

    // sstatus/sie/sip visibility masks
    localparam [31:0] SSTATUS_MASK = (1<<1)|(1<<5)|(1<<8)|(3<<9)|(1<<18)|(1<<19); // SIE,SPIE,SPP,VS,SUM,MXR
    localparam [31:0] S_INT_MASK   = (1<<1)|(1<<5)|(1<<9);          // SSI,STI,SEI

    reg [31:0] mstatus, medeleg, mideleg, mie, mtvec, mscratch, mepc, mcause, mtval;
    reg [31:0] stvec, sscratch, sepc, scause, stval, satp;
    reg [31:0] mip_sw;        // software-writable interrupt-pending bits (SSIP,STIP,SEIP)
    reg [1:0]  priv;

    assign cur_priv = priv;
    assign status_sum = mstatus[18];
    assign status_mxr = mstatus[19];
    assign status_vs  = mstatus[10:9];
    wire   sd         = (mstatus[10:9] == 2'b11);   // SD: some extension state Dirty
    assign satp_out = HAS_SATP ? satp : 32'd0;
    assign mret_target = mepc;
    assign sret_target = sepc;

    // ---- live interrupt-pending: hardware lines OR software-set bits ----
    // SEIP reads as the software bit OR the controller's line; a csrw/csrc of
    // mip only ever reaches the software bit, as the privileged spec says
    wire [31:0] mip = (mip_sw & ((1<<1)|(1<<5)|(1<<9)))     // SSIP/STIP/SEIP (sw)
                    | (s_ext_irq ? (1<<9)  : 0)             // SEIP (hardware)
                    | (timer_irq ? (1<<7)  : 0)             // MTIP (hardware)
                    | (ext_irq   ? (1<<11) : 0);            // MEIP (hardware)

    // ---- per-source interrupt evaluation, with delegation ----
    // A source fires if it is enabled+pending and globally enabled for the
    // privilege it targets, given the current privilege. An interrupt to a
    // higher privilege than the current one is always globally enabled; at
    // the same privilege it is gated by that level's interrupt-enable bit.
    // (Written as plain expressions, not a function: a continuous assign that
    // calls a function with constant arguments would only re-evaluate when
    // those arguments change, latching the time-0 value of the CSR state.)
    wire glob_m = (priv < PRIV_M) | ((priv==PRIV_M) & mstatus[3]);   // MIE
    wire glob_s = (priv < PRIV_S) | ((priv==PRIV_S) & mstatus[1]);   // SIE

    wire f_mei = (mie[11] & mip[11]) & glob_m;                       // not delegable
    wire f_msi = (mie[3]  & mip[3])  & glob_m;
    wire f_mti = (mie[7]  & mip[7])  & glob_m;
    wire f_sei = (mie[9]  & mip[9])  & (mideleg[9] ? glob_s : glob_m);
    wire f_ssi = (mie[1]  & mip[1])  & (mideleg[1] ? glob_s : glob_m);
    wire f_sti = (mie[5]  & mip[5])  & (mideleg[5] ? glob_s : glob_m);

    // standard priority: MEI, MSI, MTI, SEI, SSI, STI
    assign irq_pending = f_mei|f_msi|f_mti|f_sei|f_ssi|f_sti;
    assign irq_cause = f_mei ? 32'h8000_000B : f_msi ? 32'h8000_0003 :
                       f_mti ? 32'h8000_0007 : f_sei ? 32'h8000_0009 :
                       f_ssi ? 32'h8000_0001 : 32'h8000_0005;

    // ---- delegation decision for the trap being taken this cycle ----
    wire        is_int   = trap_cause[31];
    wire [4:0]  cidx     = trap_cause[4:0];
    wire        deleg    = (HAS_S != 0) & (priv != PRIV_M) &
                           (is_int ? mideleg[cidx] : medeleg[cidx]);
    assign deleg_now    = deleg;
    assign trap_vector  = deleg ? stvec : mtvec;

    // ---- CSR read (sstatus/sie/sip are masked views) ----
    always @(*) begin
        case (csr_addr)
            MSTATUS : csr_rdata = {sd, mstatus[30:0]};
            MEDELEG : csr_rdata = medeleg;
            MIDELEG : csr_rdata = mideleg;
            MIE_A   : csr_rdata = mie;
            MTVEC   : csr_rdata = mtvec;
            MSCRATCH: csr_rdata = mscratch;
            MEPC    : csr_rdata = mepc;
            MCAUSE  : csr_rdata = mcause;
            MTVAL   : csr_rdata = mtval;
            MIP     : csr_rdata = mip;
            SSTATUS : csr_rdata = {sd, mstatus[30:0] & SSTATUS_MASK[30:0]};
            SIE_A   : csr_rdata = mie & S_INT_MASK;
            STVEC   : csr_rdata = stvec;
            SSCRATCH: csr_rdata = sscratch;
            SEPC    : csr_rdata = sepc;
            SCAUSE  : csr_rdata = scause;
            STVAL   : csr_rdata = stval;
            SIP     : csr_rdata = mip & S_INT_MASK;
            SATP    : csr_rdata = HAS_SATP ? satp : 32'd0;
            default : csr_rdata = 32'd0;
        endcase
    end

    // MPP is WARL: it only ever holds a privilege level this hart has
    function [1:0] legal_mpp; input [1:0] m;
        legal_mpp = (m == PRIV_M)                 ? PRIV_M :
                    (m == PRIV_S && HAS_S)        ? PRIV_S :
                    (m == PRIV_U && HAS_U)        ? PRIV_U :
                    HAS_U                         ? PRIV_U : PRIV_M;
    endfunction
    localparam [1:0] LEAST = HAS_U ? PRIV_U : PRIV_M;

    function [31:0] nx;
        input [31:0] old; input [31:0] src; input [2:0] f3;
        begin case (f3[1:0])
            2'b01: nx = src; 2'b10: nx = old | src; 2'b11: nx = old & ~src;
            default: nx = old; endcase
        end
    endfunction

    // ---- sequential: trap > mret > sret > CSR write ----
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            mstatus<={19'b0, LEAST, 11'b0}; medeleg<=0; mideleg<=0; mie<=0; mtvec<=0; mscratch<=0;
            mepc<=0; mcause<=0; mtval<=0; stvec<=0; sscratch<=0; sepc<=0;
            scause<=0; stval<=0; satp<=0; mip_sw<=0; priv<=PRIV_M;
        end else if (take_trap) begin
            if (deleg) begin                          // ---- deliver to S ----
                sepc        <= pc;
                scause      <= trap_cause;
                stval       <= trap_val;
                mstatus[5]  <= mstatus[1];            // SPIE <- SIE
                mstatus[1]  <= 1'b0;                  // SIE  <- 0
                mstatus[8]  <= (priv==PRIV_S);        // SPP  <- came-from-S?
                priv        <= PRIV_S;
            end else begin                            // ---- deliver to M ----
                mepc        <= pc;
                mcause      <= trap_cause;
                mtval       <= trap_val;
                mstatus[7]  <= mstatus[3];            // MPIE <- MIE
                mstatus[3]  <= 1'b0;                  // MIE  <- 0
                mstatus[12:11] <= priv;               // MPP  <- came-from priv
                priv        <= PRIV_M;
            end
        end else if (instr_is_mret) begin
            mstatus[3]     <= mstatus[7];
            mstatus[7]     <= 1'b1;
            priv           <= mstatus[12:11];
            mstatus[12:11] <= LEAST;
        end else if (instr_is_sret) begin
            mstatus[1]     <= mstatus[5];
            mstatus[5]     <= 1'b1;
            priv           <= mstatus[8] ? PRIV_S : LEAST;
            mstatus[8]     <= 1'b0;
        end else if (csr_we) begin
            case (csr_addr)
                MSTATUS : begin
                    mstatus        <= nx(mstatus, csr_wsrc, csr_funct3);
                    mstatus[12:11] <= legal_mpp(nx(mstatus, csr_wsrc, csr_funct3) >> 11);
                end
                MEDELEG : if (HAS_S) medeleg <= nx(medeleg, csr_wsrc, csr_funct3);
                MIDELEG : if (HAS_S) mideleg <= nx(mideleg, csr_wsrc, csr_funct3);
                MIE_A   : mie      <= nx(mie,     csr_wsrc, csr_funct3);
                MTVEC   : mtvec    <= nx(mtvec,   csr_wsrc, csr_funct3);
                MSCRATCH: mscratch <= nx(mscratch,csr_wsrc, csr_funct3);
                MEPC    : mepc     <= nx(mepc,    csr_wsrc, csr_funct3);
                MCAUSE  : mcause   <= nx(mcause,  csr_wsrc, csr_funct3);
                MTVAL   : mtval    <= nx(mtval,   csr_wsrc, csr_funct3);
                MIP     : mip_sw   <= nx(mip_sw,  csr_wsrc, csr_funct3); // SSIP/STIP/SEIP
                STVEC   : stvec    <= nx(stvec,   csr_wsrc, csr_funct3);
                SSCRATCH: sscratch <= nx(sscratch,csr_wsrc, csr_funct3);
                SEPC    : sepc     <= nx(sepc,    csr_wsrc, csr_funct3);
                SCAUSE  : scause   <= nx(scause,  csr_wsrc, csr_funct3);
                STVAL   : stval    <= nx(stval,   csr_wsrc, csr_funct3);
                SATP    : if (HAS_SATP) satp <= nx(satp, csr_wsrc, csr_funct3);
                // sstatus / sie / sip write only their masked bits of the master
                SSTATUS : mstatus  <= (mstatus & ~SSTATUS_MASK) |
                                      (nx(mstatus & SSTATUS_MASK, csr_wsrc, csr_funct3) & SSTATUS_MASK);
                SIE_A   : mie      <= (mie & ~S_INT_MASK) |
                                      (nx(mie & S_INT_MASK, csr_wsrc, csr_funct3) & S_INT_MASK);
                SIP     : mip_sw   <= (mip_sw & ~(32'h1<<1)) |
                                      (nx(mip_sw & (32'h1<<1), csr_wsrc, csr_funct3) & (32'h1<<1)); // S can set SSIP
                default : ;
            endcase
        end
        // vector state changed (Step 47): VS Initial/Clean -> Dirty; Off stays Off
        if (!rst && set_vs_dirty && mstatus[10:9] != 2'b00) mstatus[10:9] <= 2'b11;
        if (!HAS_V) mstatus[10:9] <= 2'b00;
        mstatus[31] <= 1'b0;                          // SD is computed, never stored
    end
endmodule

`default_nettype wire
