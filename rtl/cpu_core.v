// =====================================================================
// cpu_core.v  -  The Step-07 CPU, refactored to expose its DATA port as
//                an external bus instead of owning the data memory.
// ---------------------------------------------------------------------
// This is identical to rtl/cpu.v except the internal `dmem` instance is
// removed and its four connections are promoted to module ports:
//   dmem_addr / dmem_wdata / dmem_we / dmem_funct3  (outputs, the master)
//   dmem_rdata                                       (input, from the bus)
// A top-level (soc.v) connects this bus to RAM and peripherals.
// Instruction fetch still uses an internal imem (a simple ROM).
// =====================================================================
`default_nettype none

module cpu_core #(
    parameter INIT_FILE = "",
    parameter RESET_PC  = 32'h0000_0000
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        timer_irq,   // level: timer interrupt request
    output wire [31:0] pc_out,
    output wire [31:0] instr_out,
    // ---- data-memory bus master ----
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire        dmem_we,
    output wire [2:0]  dmem_funct3,
    input  wire [31:0] dmem_rdata
);
    // ---- Program counter -------------------------------------------
    reg  [31:0] pc;
    wire [31:0] pc_plus4 = pc + 32'd4;
    reg  [31:0] next_pc;
    always @(posedge clk) begin
        if (rst) pc <= RESET_PC;
        else     pc <= next_pc;
    end
    assign pc_out = pc;

    // ---- Fetch ------------------------------------------------------
    wire [31:0] instr;
    assign instr_out = instr;
    imem #(.WORDS(1024), .INIT_FILE(INIT_FILE)) u_imem (
        .addr(pc), .instr(instr)
    );

    // ---- Decode fields ---------------------------------------------
    wire [6:0] opcode  = instr[6:0];
    wire [4:0] rd_addr = instr[11:7];
    wire [2:0] funct3  = instr[14:12];
    wire [4:0] rs1_addr= instr[19:15];
    wire [4:0] rs2_addr= instr[24:20];
    wire [6:0] funct7  = instr[31:25];

    // ---- Control ----------------------------------------------------
    wire       reg_write, alu_src_a, alu_src_b, mem_read, mem_write;
    wire       branch, jump, jalr;
    wire [1:0] wb_sel;
    wire [2:0] imm_type;
    wire [4:0] alu_op;
    control u_control (
        .opcode(opcode), .funct3(funct3), .funct7(funct7),
        .reg_write(reg_write), .alu_src_a(alu_src_a), .alu_src_b(alu_src_b),
        .mem_read(mem_read), .mem_write(mem_write),
        .branch(branch), .jump(jump), .jalr(jalr),
        .wb_sel(wb_sel), .imm_type(imm_type), .alu_op(alu_op)
    );

    // ---- Immediate --------------------------------------------------
    wire [31:0] imm;
    immgen u_immgen (.instr(instr), .imm_type(imm_type), .imm(imm));

    // ---- CSR / trap decode (Zicsr, machine mode) -------------------
    wire        is_system = (opcode == 7'b1110011);
    wire        is_csr    = is_system && (funct3 != 3'b000);
    wire        is_mret   = is_system && (funct3 == 3'b000) &&
                            (instr[31:20] == 12'h302);
    wire        is_ecall  = is_system && (funct3 == 3'b000) &&
                            (instr[31:20] == 12'h000);
    wire        is_ebreak = is_system && (funct3 == 3'b000) &&
                            (instr[31:20] == 12'h001);
    wire [11:0] csr_addr  = instr[31:20];
    wire [4:0]  zimm      = rs1_addr;                       // instr[19:15]
    // immediate CSR forms (funct3[2]==1) use zimm; others use rs1.
    // rs1_data is declared with the register file below; forward-declare:
    wire [31:0] rs1_data, rs2_data;
    wire [31:0] csr_wsrc = funct3[2] ? {27'b0, zimm} : rs1_data;

    wire        irq_pending;
    wire [1:0]  cur_priv;
    wire        in_user = (cur_priv == 2'b00);
    wire [31:0] csr_rdata, mtvec_out, mepc_out;

    // Illegal-instruction detection: opcodes we actually decode. Anything
    // else faults instead of silently becoming a NOP. FENCE and SYSTEM are
    // treated as legal (SYSTEM = CSR/mret; FENCE is a NOP on this in-order
    // core). An interrupt is maskable (MIE); an illegal-instruction
    // exception is NOT -- it always traps.
    wire op_known =
        (opcode==7'b0110011) || (opcode==7'b0010011) || (opcode==7'b0000011) ||
        (opcode==7'b0100011) || (opcode==7'b1100011) || (opcode==7'b1101111) ||
        (opcode==7'b1100111) || (opcode==7'b0110111) || (opcode==7'b0010111) ||
        (opcode==7'b1110011) || (opcode==7'b0001111) || (opcode==7'b0101111);  // +AMO
    // Privilege protection: user mode may not execute mret or touch the
    // machine CSRs. Attempting either is an illegal instruction.
    wire priv_violation = in_user & (is_mret | is_csr);
    wire illegal_instr  = ~op_known | priv_violation;

    // Synchronous exceptions (unmaskable) plus the maskable timer interrupt.
    wire exception = illegal_instr | is_ecall | is_ebreak;
    wire take_trap = exception | irq_pending;
    // mcause: priority illegal > ecall > ebreak > timer interrupt.
    // ecall reports a different cause from user (8) vs machine (11) mode.
    wire [31:0] trap_cause = illegal_instr ? 32'd2  :   // illegal instruction
                             is_ecall       ? (in_user ? 32'd8 : 32'd11) :
                             is_ebreak      ? 32'd3  :   // breakpoint
                                              32'h8000_0007; // M timer interrupt

    csr u_csr (
        .clk(clk), .rst(rst),
        .csr_addr(csr_addr), .csr_funct3(funct3), .csr_wsrc(csr_wsrc),
        .csr_we(is_csr & ~take_trap),
        .csr_rdata(csr_rdata),
        .pc(pc), .timer_irq(timer_irq),
        .instr_is_mret(is_mret & ~take_trap), .take_trap(take_trap),
        .trap_cause(trap_cause),
        .mtvec_out(mtvec_out), .mepc_out(mepc_out), .irq_pending(irq_pending),
        .cur_priv(cur_priv)
    );

    // ---- Register file ----------------------------------------------
    reg  [31:0] wb_data;

    // Effective write enables: a trap suppresses the interrupted
    // instruction; a CSR instruction always writes its rd.
    wire reg_write_eff = take_trap ? 1'b0 : (is_csr ? 1'b1 : reg_write);
    wire [31:0] wb_final = is_csr ? csr_rdata :
                           is_sc  ? {31'b0, ~sc_ok} :   // SC: 0 = success, 1 = fail
                                    wb_data;

    regfile u_regfile (
        .clk(clk), .we(reg_write_eff),
        .rs1_addr(rs1_addr), .rs2_addr(rs2_addr),
        .rd_addr(rd_addr),   .rd_data(wb_final),
        .rs1_data(rs1_data), .rs2_data(rs2_data)
    );

    // ---- ALU --------------------------------------------------------
    wire [31:0] alu_a = alu_src_a ? pc  : rs1_data;
    wire [31:0] alu_b = alu_src_b ? imm : rs2_data;
    wire [31:0] alu_result;
    wire        alu_zero;
    alu u_alu (
        .a(alu_a), .b(alu_b), .alu_op(alu_op),
        .result(alu_result), .zero(alu_zero)
    );

    // ---- Data bus master, with A-extension (atomics) ----------------
    wire [31:0] mem_rdata = dmem_rdata;          // combinational read of old value

    wire        is_amo_op  = (opcode == 7'b0101111);
    wire [4:0]  amo_f5     = funct7[6:2];        // funct7 = {funct5, aq, rl}
    wire        is_lr      = is_amo_op & (amo_f5 == 5'b00010);
    wire        is_sc      = is_amo_op & (amo_f5 == 5'b00011);
    wire        is_amo_rmw = is_amo_op & ~is_lr & ~is_sc;

    // Atomic read-modify-write value: op(old memory value, rs2).
    reg [31:0] amo_alu;
    always @(*) begin
        case (amo_f5)
            5'b00001: amo_alu = rs2_data;                                // AMOSWAP
            5'b00000: amo_alu = mem_rdata + rs2_data;                    // AMOADD
            5'b00100: amo_alu = mem_rdata ^ rs2_data;                    // AMOXOR
            5'b01100: amo_alu = mem_rdata & rs2_data;                    // AMOAND
            5'b01000: amo_alu = mem_rdata | rs2_data;                    // AMOOR
            5'b10000: amo_alu = ($signed(mem_rdata) < $signed(rs2_data)) ? mem_rdata : rs2_data; // AMOMIN
            5'b10100: amo_alu = ($signed(mem_rdata) > $signed(rs2_data)) ? mem_rdata : rs2_data; // AMOMAX
            5'b11000: amo_alu = (mem_rdata < rs2_data) ? mem_rdata : rs2_data; // AMOMINU
            5'b11100: amo_alu = (mem_rdata > rs2_data) ? mem_rdata : rs2_data; // AMOMAXU
            default:  amo_alu = rs2_data;
        endcase
    end

    // LR/SC reservation: a single address watched on this hart.
    reg         resv_valid;
    reg  [31:0] resv_addr;
    wire        sc_ok     = resv_valid & (resv_addr == rs1_data);
    wire        amo_store = is_amo_rmw | (is_sc & sc_ok);   // ops that write memory

    assign dmem_addr   = is_amo_op ? rs1_data : alu_result;  // atomics: addr = rs1, no imm
    assign dmem_wdata  = is_amo_rmw ? amo_alu : rs2_data;    // RMW writes the computed value
    assign dmem_we     = take_trap ? 1'b0 : (mem_write | amo_store);
    assign dmem_funct3 = is_amo_op ? 3'b010 : funct3;        // atomics are word-sized

    always @(posedge clk) begin
        if (rst)                     resv_valid <= 1'b0;
        else if (take_trap)          resv_valid <= 1'b0;     // a trap breaks an LR/SC pair
        else if (is_lr)              begin resv_valid <= 1'b1; resv_addr <= rs1_data; end
        else if (is_sc | is_amo_rmw) resv_valid <= 1'b0;     // SC and AMO clear the reservation
    end

    // ---- Branch comparator -----------------------------------------
    reg branch_cond;
    always @(*) begin
        case (funct3)
            3'b000 : branch_cond = (rs1_data == rs2_data);
            3'b001 : branch_cond = (rs1_data != rs2_data);
            3'b100 : branch_cond = ($signed(rs1_data) <  $signed(rs2_data));
            3'b101 : branch_cond = ($signed(rs1_data) >= $signed(rs2_data));
            3'b110 : branch_cond = (rs1_data <  rs2_data);
            3'b111 : branch_cond = (rs1_data >= rs2_data);
            default: branch_cond = 1'b0;
        endcase
    end
    wire branch_taken = branch & branch_cond;

    // ---- Next-PC ----------------------------------------------------
    wire [31:0] pc_target   = pc + imm;
    wire [31:0] jalr_target = {alu_result[31:1], 1'b0};
    always @(*) begin
        if      (take_trap)     next_pc = mtvec_out;   // jump to handler
        else if (is_mret)       next_pc = mepc_out;    // return from handler
        else if (jalr)          next_pc = jalr_target;
        else if (jump)          next_pc = pc_target;
        else if (branch_taken)  next_pc = pc_target;
        else                    next_pc = pc_plus4;
    end

    // ---- Write-back mux --------------------------------------------
    localparam WB_ALU=2'b00, WB_MEM=2'b01, WB_PC4=2'b10, WB_IMM=2'b11;
    always @(*) begin
        case (wb_sel)
            WB_ALU : wb_data = alu_result;
            WB_MEM : wb_data = mem_rdata;
            WB_PC4 : wb_data = pc_plus4;
            WB_IMM : wb_data = imm;
            default: wb_data = alu_result;
        endcase
    end
endmodule

`default_nettype wire
