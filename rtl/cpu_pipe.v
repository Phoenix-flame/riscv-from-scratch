// =====================================================================
// cpu_pipe.v  -  Classic 5-stage pipelined RV32IM core
// ---------------------------------------------------------------------
// Stages:  IF  -> ID -> EX -> MEM -> WB
//          fetch  decode  execute  memory  write-back
//
// Hazards handled:
//   * Data hazards     : forwarding from EX/MEM and MEM/WB into EX,
//                        plus write-in-WB / read-in-ID bypass.
//   * Load-use hazard  : one-cycle stall (a load's data isn't ready until
//                        MEM, so a dependent right behind it must wait).
//   * Control hazards  : branches/jumps resolve in EX; on taken, the two
//                        instructions behind are flushed (predict-not-taken).
//
// Not included (kept in the single-cycle cpu_core.v): CSRs / interrupts.
// Multiply/divide are combinational, so they complete in EX like any
// other ALU op -- no extra stall needed.
// =====================================================================
`default_nettype none

module cpu_pipe #(
    parameter INIT_FILE = "",
    parameter DATA_INIT = "",
    parameter RESET_PC  = 32'h0
) (
    input  wire        clk,
    input  wire        rst,
    output wire [31:0] pc_out,
    output wire [31:0] instr_out
);
    localparam NOP = 32'h00000013;          // addi x0,x0,0
    localparam WB_ALU=2'b00, WB_MEM=2'b01, WB_PC4=2'b10, WB_IMM=2'b11;

    // forward-declared cross-stage controls
    wire        ex_taken;
    wire [31:0] ex_target;
    wire        load_use;

    wire flush = ex_taken;
    wire stall = load_use & ~flush;

    // =================================================================
    // IF — instruction fetch
    // =================================================================
    reg  [31:0] pc;
    wire [31:0] pc_plus4 = pc + 32'd4;
    wire [31:0] instr_if;

    always @(posedge clk) begin
        if (rst)        pc <= RESET_PC;
        else if (flush) pc <= ex_target;
        else if (stall) pc <= pc;
        else            pc <= pc_plus4;
    end
    assign pc_out = pc;

    imem #(.WORDS(1024), .INIT_FILE(INIT_FILE)) u_imem (
        .addr(pc), .instr(instr_if)
    );

    // IF/ID pipeline register
    reg [31:0] ifid_pc, ifid_instr;
    always @(posedge clk) begin
        if (rst || flush) begin
            ifid_instr <= NOP; ifid_pc <= 32'd0;
        end else if (stall) begin
            ifid_instr <= ifid_instr; ifid_pc <= ifid_pc;  // hold
        end else begin
            ifid_instr <= instr_if; ifid_pc <= pc;
        end
    end
    assign instr_out = ifid_instr;

    // =================================================================
    // ID — decode, register read, control
    // =================================================================
    wire [6:0] opcode  = ifid_instr[6:0];
    wire [4:0] rd_id   = ifid_instr[11:7];
    wire [2:0] funct3_id = ifid_instr[14:12];
    wire [4:0] rs1_id  = ifid_instr[19:15];
    wire [4:0] rs2_id  = ifid_instr[24:20];
    wire [6:0] funct7  = ifid_instr[31:25];

    wire        c_reg_write, c_alu_src_a, c_alu_src_b, c_mem_read,
                c_mem_write, c_branch, c_jump, c_jalr;
    wire [1:0]  c_wb_sel;
    wire [2:0]  c_imm_type;
    wire [4:0]  c_alu_op;

    control u_control (
        .opcode(opcode), .funct3(funct3_id), .funct7(funct7),
        .reg_write(c_reg_write), .alu_src_a(c_alu_src_a), .alu_src_b(c_alu_src_b),
        .mem_read(c_mem_read), .mem_write(c_mem_write),
        .branch(c_branch), .jump(c_jump), .jalr(c_jalr),
        .wb_sel(c_wb_sel), .imm_type(c_imm_type), .alu_op(c_alu_op)
    );

    wire [31:0] imm_id;
    immgen u_immgen (.instr(ifid_instr), .imm_type(c_imm_type), .imm(imm_id));

    // Register file: write in WB, read in ID. We add a write->read bypass
    // (below) so an instruction in WB feeds an instruction in ID this cycle.
    wire [31:0] rf_rs1, rf_rs2;
    wire        wb_reg_write;          // MEM/WB stage (defined in WB section)
    wire [4:0]  wb_rd;
    wire [31:0] wb_data;

    regfile u_regfile (
        .clk(clk), .we(wb_reg_write),
        .rs1_addr(rs1_id), .rs2_addr(rs2_id),
        .rd_addr(wb_rd),   .rd_data(wb_data),
        .rs1_data(rf_rs1), .rs2_data(rf_rs2)
    );

    // write-in-WB / read-in-ID bypass (covers the "distance 3" hazard)
    wire [31:0] rs1_data_id = (wb_reg_write && wb_rd!=5'd0 && wb_rd==rs1_id)
                              ? wb_data : rf_rs1;
    wire [31:0] rs2_data_id = (wb_reg_write && wb_rd!=5'd0 && wb_rd==rs2_id)
                              ? wb_data : rf_rs2;

    // ID/EX pipeline register
    reg [31:0] idex_pc, idex_imm, idex_rs1d, idex_rs2d;
    reg [4:0]  idex_rs1, idex_rs2, idex_rd, idex_alu_op;
    reg [2:0]  idex_funct3;
    reg [1:0]  idex_wb_sel;
    reg        idex_reg_write, idex_alu_src_a, idex_alu_src_b,
               idex_mem_read, idex_mem_write, idex_branch, idex_jump, idex_jalr;

    // bubble = squash control so nothing commits
    wire bubble = flush | stall;
    always @(posedge clk) begin
        if (rst || bubble) begin
            idex_reg_write<=0; idex_mem_read<=0; idex_mem_write<=0;
            idex_branch<=0; idex_jump<=0; idex_jalr<=0;
            idex_alu_src_a<=0; idex_alu_src_b<=0; idex_wb_sel<=WB_ALU;
            idex_alu_op<=5'd0; idex_rd<=5'd0; idex_rs1<=5'd0; idex_rs2<=5'd0;
            idex_funct3<=3'd0; idex_pc<=0; idex_imm<=0; idex_rs1d<=0; idex_rs2d<=0;
        end else begin
            idex_reg_write<=c_reg_write; idex_mem_read<=c_mem_read;
            idex_mem_write<=c_mem_write; idex_branch<=c_branch;
            idex_jump<=c_jump; idex_jalr<=c_jalr;
            idex_alu_src_a<=c_alu_src_a; idex_alu_src_b<=c_alu_src_b;
            idex_wb_sel<=c_wb_sel; idex_alu_op<=c_alu_op;
            idex_rd<=rd_id; idex_rs1<=rs1_id; idex_rs2<=rs2_id;
            idex_funct3<=funct3_id; idex_pc<=ifid_pc; idex_imm<=imm_id;
            idex_rs1d<=rs1_data_id; idex_rs2d<=rs2_data_id;
        end
    end

    // =================================================================
    // EX — execute (with forwarding)
    // =================================================================
    // EX/MEM and MEM/WB forward sources are declared below; forward-ref:
    reg        exmem_reg_write;
    reg [4:0]  exmem_rd;
    reg [31:0] exmem_result;        // the value this instr will write back

    // forwardA / forwardB as plain continuous assignments (a function call
    // in an assign only re-evaluates on its arguments, not on exmem_*/wb_*,
    // which drops forwards when adjacent instrs share a source register).
    // Priority: EX/MEM (most recent) over MEM/WB.
    wire fwdA_exmem = exmem_reg_write && exmem_rd!=0 && exmem_rd==idex_rs1;
    wire fwdA_memwb = wb_reg_write    && wb_rd!=0    && wb_rd==idex_rs1;
    wire fwdB_exmem = exmem_reg_write && exmem_rd!=0 && exmem_rd==idex_rs2;
    wire fwdB_memwb = wb_reg_write    && wb_rd!=0    && wb_rd==idex_rs2;
    wire [31:0] opA_fwd = fwdA_exmem ? exmem_result : fwdA_memwb ? wb_data : idex_rs1d;
    wire [31:0] opB_fwd = fwdB_exmem ? exmem_result : fwdB_memwb ? wb_data : idex_rs2d;

    wire [31:0] alu_a = idex_alu_src_a ? idex_pc  : opA_fwd;
    wire [31:0] alu_b = idex_alu_src_b ? idex_imm : opB_fwd;

    wire [31:0] alu_result;
    wire        alu_zero;
    alu u_alu (.a(alu_a), .b(alu_b), .alu_op(idex_alu_op),
               .result(alu_result), .zero(alu_zero));

    // branch comparison on forwarded operands
    reg branch_cond;
    always @(*) begin
        case (idex_funct3)
            3'b000 : branch_cond = (opA_fwd == opB_fwd);
            3'b001 : branch_cond = (opA_fwd != opB_fwd);
            3'b100 : branch_cond = ($signed(opA_fwd) <  $signed(opB_fwd));
            3'b101 : branch_cond = ($signed(opA_fwd) >= $signed(opB_fwd));
            3'b110 : branch_cond = (opA_fwd <  opB_fwd);
            3'b111 : branch_cond = (opA_fwd >= opB_fwd);
            default: branch_cond = 1'b0;
        endcase
    end

    wire [31:0] pc_plus4_ex = idex_pc + 32'd4;
    wire [31:0] br_target   = idex_pc + idex_imm;
    wire [31:0] jalr_target = {alu_result[31:1], 1'b0};
    assign ex_taken  = idex_jump | (idex_branch & branch_cond);
    assign ex_target = idex_jalr ? jalr_target : br_target;

    // value this instruction will write back (everything known at EX;
    // loads are filled in at MEM)
    wire [31:0] ex_result = (idex_wb_sel==WB_PC4) ? pc_plus4_ex :
                            (idex_wb_sel==WB_IMM) ? idex_imm    :
                                                    alu_result;

    // EX/MEM pipeline register
    reg [31:0] exmem_addr, exmem_store;
    reg [2:0]  exmem_funct3;
    reg [1:0]  exmem_wb_sel;
    reg        exmem_mem_read, exmem_mem_write;
    always @(posedge clk) begin
        if (rst) begin
            exmem_reg_write<=0; exmem_mem_read<=0; exmem_mem_write<=0;
            exmem_rd<=0; exmem_result<=0; exmem_addr<=0; exmem_store<=0;
            exmem_funct3<=0; exmem_wb_sel<=WB_ALU;
        end else begin
            exmem_reg_write<=idex_reg_write; exmem_mem_read<=idex_mem_read;
            exmem_mem_write<=idex_mem_write; exmem_rd<=idex_rd;
            exmem_result<=ex_result; exmem_addr<=alu_result;
            exmem_store<=opB_fwd; exmem_funct3<=idex_funct3;
            exmem_wb_sel<=idex_wb_sel;
        end
    end

    // load-use hazard: a load in EX whose rd feeds the instruction in ID
    assign load_use = idex_mem_read && (idex_rd!=5'd0) &&
                      ((idex_rd==rs1_id) || (idex_rd==rs2_id));

    // =================================================================
    // MEM — data memory
    // =================================================================
    wire [31:0] mem_rdata;
    dmem #(.BYTES(4096), .INIT_FILE(DATA_INIT)) u_dmem (
        .clk(clk), .we(exmem_mem_write),
        .addr(exmem_addr), .wdata(exmem_store), .funct3(exmem_funct3),
        .rdata(mem_rdata)
    );

    wire [31:0] memwb_value = (exmem_wb_sel==WB_MEM) ? mem_rdata : exmem_result;

    // MEM/WB pipeline register
    reg        memwb_reg_write;
    reg [4:0]  memwb_rd;
    reg [31:0] memwb_data;
    always @(posedge clk) begin
        if (rst) begin
            memwb_reg_write<=0; memwb_rd<=0; memwb_data<=0;
        end else begin
            memwb_reg_write<=exmem_reg_write; memwb_rd<=exmem_rd;
            memwb_data<=memwb_value;
        end
    end

    // =================================================================
    // WB — write back
    // =================================================================
    assign wb_reg_write = memwb_reg_write;
    assign wb_rd        = memwb_rd;
    assign wb_data      = memwb_data;

endmodule

`default_nettype wire
