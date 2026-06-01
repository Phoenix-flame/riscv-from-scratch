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
    wire [11:0] csr_addr  = instr[31:20];
    wire [4:0]  zimm      = rs1_addr;                       // instr[19:15]
    // immediate CSR forms (funct3[2]==1) use zimm; others use rs1.
    // rs1_data is declared with the register file below; forward-declare:
    wire [31:0] rs1_data, rs2_data;
    wire [31:0] csr_wsrc = funct3[2] ? {27'b0, zimm} : rs1_data;

    wire        irq_pending;
    wire [31:0] csr_rdata, mtvec_out, mepc_out;
    wire        take_trap = irq_pending;   // single source: timer interrupt

    csr u_csr (
        .clk(clk), .rst(rst),
        .csr_addr(csr_addr), .csr_funct3(funct3), .csr_wsrc(csr_wsrc),
        .csr_we(is_csr & ~take_trap),
        .csr_rdata(csr_rdata),
        .pc(pc), .timer_irq(timer_irq),
        .instr_is_mret(is_mret & ~take_trap), .take_trap(take_trap),
        .mtvec_out(mtvec_out), .mepc_out(mepc_out), .irq_pending(irq_pending)
    );

    // ---- Register file ----------------------------------------------
    reg  [31:0] wb_data;

    // Effective write enables: a trap suppresses the interrupted
    // instruction; a CSR instruction always writes its rd.
    wire reg_write_eff = take_trap ? 1'b0 : (is_csr ? 1'b1 : reg_write);
    wire mem_write_eff = take_trap ? 1'b0 : mem_write;
    wire [31:0] wb_final = is_csr ? csr_rdata : wb_data;

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

    // ---- Data bus master (was the dmem instance) --------------------
    assign dmem_addr   = alu_result;     // address = rs1 + imm
    assign dmem_wdata  = rs2_data;
    assign dmem_we     = mem_write_eff;
    assign dmem_funct3 = funct3;
    wire [31:0] mem_rdata = dmem_rdata;

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
