// =====================================================================
// cpu_pipe_bp.v  -  5-stage pipeline with a BTB + 2-bit branch predictor
// ---------------------------------------------------------------------
// Same datapath as cpu_pipe.v (IF/ID/EX/MEM/WB, full forwarding, one-cycle
// load-use stall). The only change is *control* speculation:
//
//   * cpu_pipe.v predicts NOT-taken: every taken branch/jump flushes the two
//     instructions behind it (a fixed 2-cycle penalty per taken transfer).
//
//   * cpu_pipe_bp.v predicts in IF using a branch_predictor (BTB + 2-bit
//     counters). A correctly predicted taken branch costs 0 cycles; the
//     2-cycle flush is paid only on a *misprediction* (wrong direction, or
//     right direction but wrong target -- e.g. a jalr return).
//
// The prediction made in IF rides down the pipe (ifid_pred_*, idex_pred_*)
// and is checked against the real outcome in EX. Performance counters expose
// the control-transfer and misprediction counts so a testbench can report a
// misprediction rate and compare against the not-taken baseline.
// =====================================================================
`default_nettype none

module cpu_pipe_bp #(
    parameter INIT_FILE = "",
    parameter DATA_INIT = "",
    parameter RESET_PC  = 32'h0,
    parameter BP_IDX_BITS = 6
) (
    input  wire        clk,
    input  wire        rst,
    output wire [31:0] pc_out,
    output wire [31:0] instr_out,
    // performance counters
    output reg  [31:0] perf_cycles,
    output reg  [31:0] perf_ctrl,      // control transfers retired (br/jal/jalr)
    output reg  [31:0] perf_taken,     // of those, how many were taken
    output reg  [31:0] perf_mispred    // of those, how many were mispredicted
);
    localparam NOP = 32'h00000013;
    localparam WB_ALU=2'b00, WB_MEM=2'b01, WB_PC4=2'b10, WB_IMM=2'b11;

    // cross-stage controls (forward-declared)
    wire        ex_taken;
    wire [31:0] ex_target;
    wire        load_use;
    wire        mispred;               // EX says the prediction was wrong
    wire [31:0] redirect_pc;

    wire flush = mispred;
    wire stall = load_use & ~flush;

    // =================================================================
    // IF — fetch, with the predictor steering the next PC
    // =================================================================
    reg  [31:0] pc;
    wire [31:0] pc_plus4 = pc + 32'd4;
    wire [31:0] instr_if;

    wire        predict_taken;
    wire [31:0] predict_target;

    always @(posedge clk) begin
        if (rst)                pc <= RESET_PC;
        else if (flush)         pc <= redirect_pc;     // recover from a misprediction
        else if (stall)         pc <= pc;
        else if (predict_taken) pc <= predict_target;  // speculate to the BTB target
        else                    pc <= pc_plus4;
    end
    assign pc_out = pc;

    imem #(.WORDS(1024), .INIT_FILE(INIT_FILE)) u_imem (
        .addr(pc), .instr(instr_if)
    );

    // IF/ID pipeline register (now also carries the prediction)
    reg [31:0] ifid_pc, ifid_instr, ifid_pred_target;
    reg        ifid_pred_taken;
    always @(posedge clk) begin
        if (rst || flush) begin
            ifid_instr <= NOP; ifid_pc <= 32'd0;
            ifid_pred_taken <= 1'b0; ifid_pred_target <= 32'd0;
        end else if (stall) begin
            ifid_instr <= ifid_instr; ifid_pc <= ifid_pc;
            ifid_pred_taken <= ifid_pred_taken; ifid_pred_target <= ifid_pred_target;
        end else begin
            ifid_instr <= instr_if; ifid_pc <= pc;
            ifid_pred_taken <= predict_taken; ifid_pred_target <= predict_target;
        end
    end
    assign instr_out = ifid_instr;

    // =================================================================
    // ID — decode, register read, control
    // =================================================================
    wire [6:0] opcode    = ifid_instr[6:0];
    wire [4:0] rd_id     = ifid_instr[11:7];
    wire [2:0] funct3_id = ifid_instr[14:12];
    wire [4:0] rs1_id    = ifid_instr[19:15];
    wire [4:0] rs2_id    = ifid_instr[24:20];
    wire [6:0] funct7    = ifid_instr[31:25];

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

    wire [31:0] rf_rs1, rf_rs2;
    wire        wb_reg_write;
    wire [4:0]  wb_rd;
    wire [31:0] wb_data;

    regfile u_regfile (
        .clk(clk), .we(wb_reg_write),
        .rs1_addr(rs1_id), .rs2_addr(rs2_id),
        .rd_addr(wb_rd),   .rd_data(wb_data),
        .rs1_data(rf_rs1), .rs2_data(rf_rs2)
    );

    wire [31:0] rs1_data_id = (wb_reg_write && wb_rd!=5'd0 && wb_rd==rs1_id)
                              ? wb_data : rf_rs1;
    wire [31:0] rs2_data_id = (wb_reg_write && wb_rd!=5'd0 && wb_rd==rs2_id)
                              ? wb_data : rf_rs2;

    // ID/EX pipeline register
    reg [31:0] idex_pc, idex_imm, idex_rs1d, idex_rs2d, idex_pred_target;
    reg [4:0]  idex_rs1, idex_rs2, idex_rd, idex_alu_op;
    reg [2:0]  idex_funct3;
    reg [1:0]  idex_wb_sel;
    reg        idex_reg_write, idex_alu_src_a, idex_alu_src_b,
               idex_mem_read, idex_mem_write, idex_branch, idex_jump, idex_jalr,
               idex_pred_taken;

    wire bubble = flush | stall;
    always @(posedge clk) begin
        if (rst || bubble) begin
            idex_reg_write<=0; idex_mem_read<=0; idex_mem_write<=0;
            idex_branch<=0; idex_jump<=0; idex_jalr<=0;
            idex_alu_src_a<=0; idex_alu_src_b<=0; idex_wb_sel<=WB_ALU;
            idex_alu_op<=5'd0; idex_rd<=5'd0; idex_rs1<=5'd0; idex_rs2<=5'd0;
            idex_funct3<=3'd0; idex_pc<=0; idex_imm<=0; idex_rs1d<=0; idex_rs2d<=0;
            idex_pred_taken<=0; idex_pred_target<=0;
        end else begin
            idex_reg_write<=c_reg_write; idex_mem_read<=c_mem_read;
            idex_mem_write<=c_mem_write; idex_branch<=c_branch;
            idex_jump<=c_jump; idex_jalr<=c_jalr;
            idex_alu_src_a<=c_alu_src_a; idex_alu_src_b<=c_alu_src_b;
            idex_wb_sel<=c_wb_sel; idex_alu_op<=c_alu_op;
            idex_rd<=rd_id; idex_rs1<=rs1_id; idex_rs2<=rs2_id;
            idex_funct3<=funct3_id; idex_pc<=ifid_pc; idex_imm<=imm_id;
            idex_rs1d<=rs1_data_id; idex_rs2d<=rs2_data_id;
            idex_pred_taken<=ifid_pred_taken; idex_pred_target<=ifid_pred_target;
        end
    end

    // =================================================================
    // EX — execute (with forwarding) + branch resolution & checking
    // =================================================================
    reg        exmem_reg_write;
    reg [4:0]  exmem_rd;
    reg [31:0] exmem_result;

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

    // ---- check the IF-stage prediction against reality ----
    wire ex_is_ctrl = idex_branch | idex_jump | idex_jalr;
    wire dir_wrong  = ex_is_ctrl & (ex_taken != idex_pred_taken);
    wire tgt_wrong  = ex_is_ctrl & ex_taken & idex_pred_taken & (ex_target != idex_pred_target);
    assign mispred      = dir_wrong | tgt_wrong;
    assign redirect_pc  = ex_taken ? ex_target : pc_plus4_ex;

    // ---- predictor: lookup in IF, train in EX ----
    branch_predictor #(.IDX_BITS(BP_IDX_BITS)) u_bp (
        .clk(clk), .rst(rst),
        .pc_if(pc), .predict_taken(predict_taken), .predict_target(predict_target),
        .upd_en(ex_is_ctrl), .upd_pc(idex_pc), .upd_taken(ex_taken),
        .upd_is_jump(idex_jump | idex_jalr), .upd_target(ex_target)
    );

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

    assign load_use = idex_mem_read && (idex_rd!=5'd0) &&
                      ((idex_rd==rs1_id) || (idex_rd==rs2_id));

    // =================================================================
    // MEM
    // =================================================================
    wire [31:0] mem_rdata;
    dmem #(.BYTES(4096), .INIT_FILE(DATA_INIT)) u_dmem (
        .clk(clk), .we(exmem_mem_write),
        .addr(exmem_addr), .wdata(exmem_store), .funct3(exmem_funct3),
        .rdata(mem_rdata)
    );

    wire [31:0] memwb_value = (exmem_wb_sel==WB_MEM) ? mem_rdata : exmem_result;

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
    // WB
    // =================================================================
    assign wb_reg_write = memwb_reg_write;
    assign wb_rd        = memwb_rd;
    assign wb_data      = memwb_data;

    // =================================================================
    // performance counters
    // =================================================================
    always @(posedge clk) begin
        if (rst) begin
            perf_cycles<=0; perf_ctrl<=0; perf_taken<=0; perf_mispred<=0;
        end else begin
            perf_cycles <= perf_cycles + 1;
            if (ex_is_ctrl) begin
                perf_ctrl <= perf_ctrl + 1;
                if (ex_taken) perf_taken   <= perf_taken   + 1;
                if (mispred)  perf_mispred <= perf_mispred + 1;
            end
        end
    end

endmodule

`default_nettype wire
