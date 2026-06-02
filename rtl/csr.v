// =====================================================================
// csr.v  -  Machine-mode CSRs + trap controller (minimal Zicsr)
// ---------------------------------------------------------------------
// Holds the control/status registers needed for interrupts, services
// the CSR instructions (csrrw/s/c and immediate forms), and implements
// the trap entry / mret exit side effects.
//
// Supported CSRs:
//   mstatus (0x300): bit3 MIE (global enable), bit7 MPIE (previous MIE)
//   mie     (0x304): bit7 MTIE (machine timer interrupt enable)
//   mtvec   (0x305): trap handler base address (direct mode)
//   mscratch(0x340): scratch register
//   mepc    (0x341): PC saved on trap
//   mcause  (0x342): cause of the trap
//   mip     (0x344): bit7 MTIP (machine timer interrupt pending, read-only)
// =====================================================================
`default_nettype none

module csr (
    input  wire        clk,
    input  wire        rst,

    // CSR instruction port
    input  wire [11:0] csr_addr,
    input  wire [2:0]  csr_funct3,  // low 2 bits pick rw/rs/rc
    input  wire [31:0] csr_wsrc,    // rs1 value, or zero-extended zimm
    input  wire        csr_we,      // a CSR instruction is committing
    output reg  [31:0] csr_rdata,   // current value (written to rd)

    // trap interface
    input  wire [31:0] pc,          // PC of the interrupted/faulting instruction
    input  wire        timer_irq,   // level: timer says "fire"
    input  wire        instr_is_mret,
    input  wire        take_trap,   // computed in the core this cycle
    input  wire        is_illegal,  // trap is a synchronous illegal-instruction
    output wire [31:0] mtvec_out,
    output wire [31:0] mepc_out,
    output wire        irq_pending  // MIE & MTIE & timer_irq
);
    localparam MSTATUS=12'h300, MIE_A=12'h304, MTVEC=12'h305,
               MSCRATCH=12'h340, MEPC=12'h341, MCAUSE=12'h342, MIP=12'h344;

    reg [31:0] mstatus, mie, mtvec, mscratch, mepc, mcause;

    wire mstatus_mie  = mstatus[3];
    wire mstatus_mpie = mstatus[7];
    wire mie_mtie     = mie[7];

    assign irq_pending = mstatus_mie & mie_mtie & timer_irq;
    assign mtvec_out   = mtvec;
    assign mepc_out    = mepc;

    // Compute the next value of a CSR for a csrrw/s/c-style write.
    function [31:0] csr_next;
        input [31:0] old;
        input [31:0] src;
        input [2:0]  f3;
        begin
            case (f3[1:0])
                2'b01:   csr_next = src;          // csrrw  / csrrwi
                2'b10:   csr_next = old | src;    // csrrs  / csrrsi
                2'b11:   csr_next = old & ~src;   // csrrc  / csrrci
                default: csr_next = old;
            endcase
        end
    endfunction

    // ---- Combinational read ----
    always @(*) begin
        case (csr_addr)
            MSTATUS : csr_rdata = mstatus;
            MIE_A   : csr_rdata = mie;
            MTVEC   : csr_rdata = mtvec;
            MSCRATCH: csr_rdata = mscratch;
            MEPC    : csr_rdata = mepc;
            MCAUSE  : csr_rdata = mcause;
            MIP     : csr_rdata = {24'b0, timer_irq, 7'b0}; // MTIP at bit 7
            default : csr_rdata = 32'd0;
        endcase
    end

    // ---- Sequential update: trap > mret > CSR write ----
    always @(posedge clk) begin
        if (rst) begin
            mstatus  <= 32'd0;
            mie      <= 32'd0;
            mtvec    <= 32'd0;
            mscratch <= 32'd0;
            mepc     <= 32'd0;
            mcause   <= 32'd0;
        end else if (take_trap) begin
            mepc       <= pc;                 // resume/faulting instruction
            // illegal instruction = synchronous exception, cause 2 (bit31=0)
            // timer interrupt      = asynchronous, cause 7 with bit31 set
            mcause     <= is_illegal ? 32'h0000_0002 : 32'h8000_0007;
            mstatus[7] <= mstatus[3];         // MPIE <- MIE
            mstatus[3] <= 1'b0;               // MIE  <- 0 (disable during ISR)
        end else if (instr_is_mret) begin
            mstatus[3]  <= mstatus[7];         // MIE  <- MPIE
            mstatus[7]  <= 1'b1;               // MPIE <- 1
        end else if (csr_we) begin
            case (csr_addr)
                MSTATUS : mstatus  <= csr_next(mstatus,  csr_wsrc, csr_funct3);
                MIE_A   : mie      <= csr_next(mie,      csr_wsrc, csr_funct3);
                MTVEC   : mtvec    <= csr_next(mtvec,    csr_wsrc, csr_funct3);
                MSCRATCH: mscratch <= csr_next(mscratch, csr_wsrc, csr_funct3);
                MEPC    : mepc     <= csr_next(mepc,     csr_wsrc, csr_funct3);
                MCAUSE  : mcause   <= csr_next(mcause,   csr_wsrc, csr_funct3);
                default : ; // mip is read-only here
            endcase
        end
    end
endmodule

`default_nettype wire
