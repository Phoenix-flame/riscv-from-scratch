// =====================================================================
// cpu_pipe_trap.v  -  5-stage pipelined RV32IM + Zicsr with PRECISE traps
// ---------------------------------------------------------------------
// Extends cpu_pipe.v (forwarding + load-use stall + branch flush) with
// machine-mode CSRs, interrupts, and synchronous exceptions (illegal
// instruction, ecall, ebreak).
//
// Precise-exception strategy: traps are COMMITTED in the EX stage. When
// the instruction in EX traps:
//   * instructions OLDER than it (already in MEM/WB) complete normally;
//   * the trapping instruction itself is squashed (no reg/mem write);
//   * instructions YOUNGER than it (in ID/IF) are flushed;
//   * mepc = that instruction's PC, PC redirects to mtvec.
// Because our only exception sources are detectable by EX, committing in
// EX yields a precise machine state -- mepc names exactly one boundary.
// =====================================================================
`default_nettype none

module cpu_pipe_trap #(
    parameter INIT_FILE = "",
    parameter DATA_INIT = "",
    parameter RESET_PC  = 32'h0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        timer_irq,
    output wire [31:0] pc_out,
    output wire [31:0] instr_out,
    // data-memory bus master (to the SoC interconnect)
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire        dmem_we,
    output wire [2:0]  dmem_funct3,
    input  wire [31:0] dmem_rdata
);
    localparam NOP = 32'h00000013;
    localparam WB_ALU=2'b00, WB_MEM=2'b01, WB_PC4=2'b10, WB_IMM=2'b11;

    // cross-stage control (resolved in EX)
    wire        redirect;
    wire [31:0] redirect_pc;
    wire        load_use;

    wire flush = redirect;
    wire stall = load_use & ~flush;

    // =================================================================
    // IF
    // =================================================================
    reg  [31:0] pc;
    wire [31:0] pc_plus4 = pc + 32'd4;
    wire [31:0] instr_if;
    always @(posedge clk) begin
        if (rst)        pc <= RESET_PC;
        else if (flush) pc <= redirect_pc;
        else if (stall) pc <= pc;
        else            pc <= pc_plus4;
    end
    assign pc_out = pc;

    imem #(.WORDS(1024), .INIT_FILE(INIT_FILE)) u_imem (.addr(pc), .instr(instr_if));

    reg [31:0] ifid_pc, ifid_instr;
    reg        ifid_valid;            // 0 for flush-injected filler NOPs
    always @(posedge clk) begin
        if (rst || flush)      begin ifid_instr <= NOP; ifid_pc <= 32'd0; ifid_valid <= 1'b0; end
        else if (stall)        begin ifid_instr <= ifid_instr; ifid_pc <= ifid_pc; ifid_valid <= ifid_valid; end
        else                   begin ifid_instr <= instr_if; ifid_pc <= pc; ifid_valid <= 1'b1; end
    end
    assign instr_out = ifid_instr;

    // =================================================================
    // ID
    // =================================================================
    wire [6:0] opcode    = ifid_instr[6:0];
    wire [4:0] rd_id     = ifid_instr[11:7];
    wire [2:0] funct3_id = ifid_instr[14:12];
    wire [4:0] rs1_id    = ifid_instr[19:15];
    wire [4:0] rs2_id    = ifid_instr[24:20];
    wire [6:0] funct7    = ifid_instr[31:25];

    wire c_reg_write, c_alu_src_a, c_alu_src_b, c_mem_read, c_mem_write,
         c_branch, c_jump, c_jalr;
    wire [1:0] c_wb_sel;
    wire [2:0] c_imm_type;
    wire [4:0] c_alu_op;
    control u_control (
        .opcode(opcode), .funct3(funct3_id), .funct7(funct7),
        .reg_write(c_reg_write), .alu_src_a(c_alu_src_a), .alu_src_b(c_alu_src_b),
        .mem_read(c_mem_read), .mem_write(c_mem_write),
        .branch(c_branch), .jump(c_jump), .jalr(c_jalr),
        .wb_sel(c_wb_sel), .imm_type(c_imm_type), .alu_op(c_alu_op)
    );

    wire [31:0] imm_id;
    immgen u_immgen (.instr(ifid_instr), .imm_type(c_imm_type), .imm(imm_id));

    // SYSTEM / CSR / exception decode (ID)
    wire is_system = (opcode == 7'b1110011);
    wire id_is_csr = is_system && (funct3_id != 3'b000);
    wire id_is_mret= is_system && (funct3_id==3'b000) && (ifid_instr[31:20]==12'h302);
    wire id_ecall  = is_system && (funct3_id==3'b000) && (ifid_instr[31:20]==12'h000);
    wire id_ebreak = is_system && (funct3_id==3'b000) && (ifid_instr[31:20]==12'h001);
    wire op_known =
        (opcode==7'b0110011)||(opcode==7'b0010011)||(opcode==7'b0000011)||
        (opcode==7'b0100011)||(opcode==7'b1100011)||(opcode==7'b1101111)||
        (opcode==7'b1100111)||(opcode==7'b0110111)||(opcode==7'b0010111)||
        (opcode==7'b1110011)||(opcode==7'b0001111);
    wire id_illegal = ~op_known;

    // register read with WB->ID bypass
    wire [31:0] rf_rs1, rf_rs2;
    wire        wb_reg_write; wire [4:0] wb_rd; wire [31:0] wb_data;
    regfile u_regfile (
        .clk(clk), .we(wb_reg_write),
        .rs1_addr(rs1_id), .rs2_addr(rs2_id),
        .rd_addr(wb_rd), .rd_data(wb_data),
        .rs1_data(rf_rs1), .rs2_data(rf_rs2)
    );
    wire [31:0] rs1_data_id = (wb_reg_write && wb_rd!=0 && wb_rd==rs1_id) ? wb_data : rf_rs1;
    wire [31:0] rs2_data_id = (wb_reg_write && wb_rd!=0 && wb_rd==rs2_id) ? wb_data : rf_rs2;

    // ID/EX register
    reg [31:0] idex_pc, idex_imm, idex_rs1d, idex_rs2d;
    reg [4:0]  idex_rs1, idex_rs2, idex_rd, idex_alu_op;
    reg [2:0]  idex_funct3;
    reg [1:0]  idex_wb_sel;
    reg [11:0] idex_csr_addr;
    reg        idex_reg_write, idex_alu_src_a, idex_alu_src_b,
               idex_mem_read, idex_mem_write, idex_branch, idex_jump, idex_jalr,
               idex_is_csr, idex_is_mret, idex_ecall, idex_ebreak, idex_illegal,
               idex_valid;

    wire ex_squash;                 // defined in EX; squashes trapping instr
    wire bubble = flush | stall;
    always @(posedge clk) begin
        if (rst || bubble) begin
            idex_reg_write<=0; idex_mem_read<=0; idex_mem_write<=0;
            idex_branch<=0; idex_jump<=0; idex_jalr<=0; idex_alu_src_a<=0;
            idex_alu_src_b<=0; idex_wb_sel<=WB_ALU; idex_alu_op<=0;
            idex_rd<=0; idex_rs1<=0; idex_rs2<=0; idex_funct3<=0;
            idex_pc<=0; idex_imm<=0; idex_rs1d<=0; idex_rs2d<=0;
            idex_is_csr<=0; idex_is_mret<=0; idex_ecall<=0; idex_ebreak<=0;
            idex_illegal<=0; idex_csr_addr<=0; idex_valid<=0;
        end else begin
            idex_reg_write<=c_reg_write; idex_mem_read<=c_mem_read;
            idex_mem_write<=c_mem_write; idex_branch<=c_branch;
            idex_jump<=c_jump; idex_jalr<=c_jalr; idex_alu_src_a<=c_alu_src_a;
            idex_alu_src_b<=c_alu_src_b; idex_wb_sel<=c_wb_sel; idex_alu_op<=c_alu_op;
            idex_rd<=rd_id; idex_rs1<=rs1_id; idex_rs2<=rs2_id; idex_funct3<=funct3_id;
            idex_pc<=ifid_pc; idex_imm<=imm_id; idex_rs1d<=rs1_data_id; idex_rs2d<=rs2_data_id;
            idex_is_csr<=id_is_csr; idex_is_mret<=id_is_mret; idex_ecall<=id_ecall;
            idex_ebreak<=id_ebreak; idex_illegal<=id_illegal;
            idex_csr_addr<=ifid_instr[31:20]; idex_valid<=ifid_valid;
        end
    end

    // =================================================================
    // EX  (+ trap commit, CSR access)
    // =================================================================
    reg        exmem_reg_write; reg [4:0] exmem_rd; reg [31:0] exmem_result;

    // Forwarding selects as plain continuous assignments. (Do NOT wrap this
    // in a Verilog function called from an assign: such a call only re-
    // evaluates when its arguments change, not when exmem_*/wb_* change,
    // which silently drops forwards when two adjacent instrs share a source
    // register.) Priority: EX/MEM (most recent) over MEM/WB.
    wire fwdA_exmem = exmem_reg_write && exmem_rd!=0 && exmem_rd==idex_rs1;
    wire fwdA_memwb = wb_reg_write    && wb_rd!=0    && wb_rd==idex_rs1;
    wire fwdB_exmem = exmem_reg_write && exmem_rd!=0 && exmem_rd==idex_rs2;
    wire fwdB_memwb = wb_reg_write    && wb_rd!=0    && wb_rd==idex_rs2;
    wire [31:0] opA = fwdA_exmem ? exmem_result : fwdA_memwb ? wb_data : idex_rs1d;
    wire [31:0] opB = fwdB_exmem ? exmem_result : fwdB_memwb ? wb_data : idex_rs2d;

    wire [31:0] alu_a = idex_alu_src_a ? idex_pc  : opA;
    wire [31:0] alu_b = idex_alu_src_b ? idex_imm : opB;
    wire [31:0] alu_result; wire alu_zero;
    alu u_alu (.a(alu_a), .b(alu_b), .alu_op(idex_alu_op), .result(alu_result), .zero(alu_zero));

    reg branch_cond;
    always @(*) case (idex_funct3)
        3'b000: branch_cond=(opA==opB);
        3'b001: branch_cond=(opA!=opB);
        3'b100: branch_cond=($signed(opA)<$signed(opB));
        3'b101: branch_cond=($signed(opA)>=$signed(opB));
        3'b110: branch_cond=(opA<opB);
        3'b111: branch_cond=(opA>=opB);
        default:branch_cond=1'b0;
    endcase

    wire [31:0] pc4_ex    = idex_pc + 32'd4;
    wire [31:0] br_target = idex_pc + idex_imm;
    wire [31:0] jalr_tgt  = {alu_result[31:1], 1'b0};
    wire ex_taken = idex_valid & (idex_jump | (idex_branch & branch_cond));
    wire [31:0] ex_target = idex_jalr ? jalr_tgt : br_target;

    // ---- CSR + trap (committed in EX) ----
    wire [31:0] csr_rdata, mtvec_out, mepc_out;
    wire        irq_pending;
    wire        csr_is_imm = idex_funct3[2];
    wire [31:0] csr_wsrc   = csr_is_imm ? {27'b0, idex_rs1} : opA;

    wire exception = idex_valid & (idex_illegal | idex_ecall | idex_ebreak);
    wire irq_take  = idex_valid & irq_pending & ~exception &
                     ~idex_is_mret & ~idex_is_csr;
    wire take_trap = exception | irq_take;
    wire mret_ex   = idex_valid & idex_is_mret & ~take_trap;
    wire csr_commit= idex_valid & idex_is_csr  & ~take_trap;

    wire [31:0] trap_cause = idex_illegal ? 32'd2  :
                             idex_ecall   ? 32'd11 :
                             idex_ebreak  ? 32'd3  : 32'h8000_0007;

    csr u_csr (
        .clk(clk), .rst(rst),
        .csr_addr(idex_csr_addr), .csr_funct3(idex_funct3), .csr_wsrc(csr_wsrc),
        .csr_we(csr_commit), .csr_rdata(csr_rdata),
        .pc(idex_pc), .timer_irq(timer_irq), .ext_irq(1'b0),
        .instr_is_mret(mret_ex), .take_trap(take_trap), .trap_cause(trap_cause),
        .mtvec_out(mtvec_out), .mepc_out(mepc_out), .irq_pending(irq_pending)
    );

    assign ex_squash   = take_trap;        // squash the trapping instruction
    assign redirect    = take_trap | mret_ex | ex_taken;
    assign redirect_pc = take_trap ? mtvec_out :
                         mret_ex   ? mepc_out  : ex_target;

    // value this instruction writes back
    wire [31:0] ex_result = idex_is_csr           ? csr_rdata :
                            (idex_wb_sel==WB_PC4)  ? pc4_ex    :
                            (idex_wb_sel==WB_IMM)  ? idex_imm  : alu_result;
    wire ex_reg_write = ex_squash ? 1'b0 : (idex_is_csr ? 1'b1 : idex_reg_write);
    wire ex_mem_write = ex_squash ? 1'b0 : idex_mem_write;

    // EX/MEM register
    reg [31:0] exmem_addr, exmem_store; reg [2:0] exmem_funct3;
    reg [1:0]  exmem_wb_sel; reg exmem_mem_read, exmem_mem_write;
    always @(posedge clk) begin
        if (rst) begin
            exmem_reg_write<=0; exmem_mem_read<=0; exmem_mem_write<=0;
            exmem_rd<=0; exmem_result<=0; exmem_addr<=0; exmem_store<=0;
            exmem_funct3<=0; exmem_wb_sel<=WB_ALU;
        end else begin
            exmem_reg_write<=ex_reg_write; exmem_mem_read<=idex_mem_read & ~ex_squash;
            exmem_mem_write<=ex_mem_write; exmem_rd<=idex_rd;
            exmem_result<=ex_result; exmem_addr<=alu_result; exmem_store<=opB;
            exmem_funct3<=idex_funct3;
            exmem_wb_sel<=idex_is_csr ? WB_ALU : idex_wb_sel; // csr already in result
        end
    end

    assign load_use = idex_mem_read && idex_rd!=0 &&
                      ((idex_rd==rs1_id) || (idex_rd==rs2_id));

    // =================================================================
    // MEM  (data access goes out the external bus to the SoC)
    // =================================================================
    assign dmem_addr   = exmem_addr;
    assign dmem_wdata  = exmem_store;
    assign dmem_we     = exmem_mem_write;
    assign dmem_funct3 = exmem_funct3;
    wire [31:0] mem_rdata = dmem_rdata;
    wire [31:0] memwb_value = (exmem_wb_sel==WB_MEM) ? mem_rdata : exmem_result;

    reg memwb_reg_write; reg [4:0] memwb_rd; reg [31:0] memwb_data;
    always @(posedge clk) begin
        if (rst) begin memwb_reg_write<=0; memwb_rd<=0; memwb_data<=0; end
        else begin
            memwb_reg_write<=exmem_reg_write; memwb_rd<=exmem_rd; memwb_data<=memwb_value;
        end
    end

    // =================================================================
    // WB
    // =================================================================
    assign wb_reg_write = memwb_reg_write;
    assign wb_rd        = memwb_rd;
    assign wb_data      = memwb_data;
endmodule

`default_nettype wire
