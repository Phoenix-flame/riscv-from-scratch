// =====================================================================
// cpu_mc_stall.v  -  Multi-cycle RV32IM core with a STALL-CAPABLE data bus
// ---------------------------------------------------------------------
// cpu_mc assumes the data memory answers in a fixed single cycle: it
// presents a load address in EXEC and the registered word is simply there
// in MEM. That is true for block RAM, but not for anything with variable
// latency -- an AXI slave, the Zynq DDR behind an AXI-HP port, a PS
// peripheral. Those answer when they answer, after an arbitrary number of
// cycles of handshaking.
//
// This core adds one input -- `dmem_ready` -- and the discipline to wait on
// it. Loads AND stores now go through the MEM state, assert their request
// there (re / we are MEM-phase only, so a slave with read/write side effects
// never sees a spurious EXEC-phase strobe), and the core holds in MEM,
// request asserted and PC frozen, until the slave raises `dmem_ready`. For a
// load, `dmem_rdata` is sampled on the ready cycle; for a store, ready just
// means the write was accepted. A always-ready slave (block RAM tying
// dmem_ready=1) behaves exactly as before for loads and costs stores one
// extra cycle (they now take the uniform load path).
//
// Traps are still only taken in EXEC, so an interrupt that becomes pending
// mid-transfer cannot abort an in-flight bus access -- it is taken at the
// next instruction, after the access drains.
// =====================================================================
`default_nettype none

module cpu_mc_stall #(
    parameter RESET_PC = 32'h0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        timer_irq,
    input  wire        ext_irq,
    input  wire        halt,
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_rdata,
    output wire [31:0] dmem_addr,
    output wire [3:0]  dmem_we,
    output wire        dmem_re,
    output wire [31:0] dmem_wdata,
    input  wire [31:0] dmem_rdata,
    input  wire        dmem_ready,           // NEW: slave transfer-complete
    output wire [31:0] pc_out
);
    localparam S_FETCH=2'd0, S_EXEC=2'd1, S_MEM=2'd2, S_HALT=2'd3;
    reg [1:0]  state;
    reg [31:0] pc;

    assign imem_addr = pc;
    assign pc_out    = pc;
    wire [31:0] instr = imem_rdata;

    wire in_exec = (state == S_EXEC);
    wire in_mem  = (state == S_MEM);

    // ---- decode ----
    wire [6:0] opcode  = instr[6:0];
    wire [4:0] rd_addr = instr[11:7];
    wire [2:0] funct3  = instr[14:12];
    wire [4:0] rs1_addr= instr[19:15];
    wire [4:0] rs2_addr= instr[24:20];
    wire [6:0] funct7  = instr[31:25];

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

    wire [31:0] imm;
    immgen u_immgen (.instr(instr), .imm_type(imm_type), .imm(imm));

    // ---- CSR / trap / privilege decode ----
    wire        is_system = (opcode == 7'b1110011);
    wire        is_csr    = is_system && (funct3 != 3'b000);
    wire        is_mret   = is_system && (funct3==3'b000) && (instr[31:20]==12'h302);
    wire        is_ecall  = is_system && (funct3==3'b000) && (instr[31:20]==12'h000);
    wire        is_ebreak = is_system && (funct3==3'b000) && (instr[31:20]==12'h001);
    wire [11:0] csr_addr  = instr[31:20];
    wire [4:0]  zimm      = rs1_addr;
    wire [31:0] rs1_data, rs2_data;
    wire [31:0] csr_wsrc  = funct3[2] ? {27'b0, zimm} : rs1_data;

    wire        irq_pending;
    wire [31:0] irq_cause;
    wire [1:0]  cur_priv;
    wire        in_user = (cur_priv == 2'b00);
    wire [31:0] csr_rdata, mtvec_out, mepc_out;

    wire op_known =
        (opcode==7'b0110011)||(opcode==7'b0010011)||(opcode==7'b0000011)||
        (opcode==7'b0100011)||(opcode==7'b1100011)||(opcode==7'b1101111)||
        (opcode==7'b1100111)||(opcode==7'b0110111)||(opcode==7'b0010111)||
        (opcode==7'b1110011)||(opcode==7'b0001111);
    wire priv_violation = in_user & (is_mret | is_csr);
    wire illegal_instr  = ~op_known | priv_violation;

    wire exception = illegal_instr | is_ecall | is_ebreak;
    wire take_trap = exception | (irq_pending & ~is_mret);
    wire [31:0] trap_cause = illegal_instr ? 32'd2  :
                             is_ecall       ? (in_user ? 32'd8 : 32'd11) :
                             is_ebreak      ? 32'd3  :
                                              irq_cause;

    csr u_csr (
        .clk(clk), .rst(rst),
        .csr_addr(csr_addr), .csr_funct3(funct3), .csr_wsrc(csr_wsrc),
        .csr_we(is_csr & in_exec & ~take_trap),
        .csr_rdata(csr_rdata),
        .pc(pc), .timer_irq(timer_irq), .ext_irq(ext_irq),
        .instr_is_mret(is_mret & in_exec & ~take_trap),
        .take_trap(take_trap & in_exec),
        .trap_cause(trap_cause),
        .mtvec_out(mtvec_out), .mepc_out(mepc_out), .irq_pending(irq_pending), .irq_cause(irq_cause),
        .cur_priv(cur_priv)
    );

    // ---- register file ----
    reg  [31:0] wb_data;
    reg         rf_we;
    wire [31:0] wb_final = is_csr ? csr_rdata : wb_data;
    regfile u_regfile (
        .clk(clk), .we(rf_we),
        .rs1_addr(rs1_addr), .rs2_addr(rs2_addr),
        .rd_addr(rd_addr),   .rd_data(wb_final),
        .rs1_data(rs1_data), .rs2_data(rs2_data)
    );

    // ---- ALU ----
    wire [31:0] alu_a = alu_src_a ? pc  : rs1_data;
    wire [31:0] alu_b = alu_src_b ? imm : rs2_data;
    wire [31:0] alu_result;
    wire        alu_zero;
    alu u_alu (.a(alu_a), .b(alu_b), .alu_op(alu_op),
               .result(alu_result), .zero(alu_zero));

    // ---- data bus: request asserted in MEM only (the committed access) ----
    wire [1:0] ba = alu_result[1:0];
    assign dmem_addr  = alu_result;
    assign dmem_wdata = (funct3==3'b000) ? (rs2_data[7:0]  <<  (8*ba)) :     // SB
                        (funct3==3'b001) ? (rs2_data[15:0] << (8*ba)) :      // SH
                                            rs2_data;                        // SW
    wire [3:0] wmask  = (funct3==3'b000) ? (4'b0001 << ba) :                 // SB
                        (funct3==3'b001) ? (4'b0011 << ba) :                 // SH
                                            4'b1111;                         // SW
    // MEM-phase strobes: no spurious EXEC-phase access, so a variable-latency
    // slave begins its transaction exactly once, when the access truly commits.
    assign dmem_we = (in_mem & mem_write) ? wmask : 4'b0000;
    assign dmem_re =  in_mem & mem_read;

    // ---- load extraction (valid on the ready cycle) ----
    wire [31:0] dw = dmem_rdata;
    reg  [31:0] load_val;
    always @(*) begin
        case (funct3)
            3'b000: case (ba)                            // LB
                2'd0: load_val = {{24{dw[7]}},  dw[7:0]};
                2'd1: load_val = {{24{dw[15]}}, dw[15:8]};
                2'd2: load_val = {{24{dw[23]}}, dw[23:16]};
                default: load_val = {{24{dw[31]}}, dw[31:24]};
            endcase
            3'b001: load_val = ba[1] ? {{16{dw[31]}}, dw[31:16]}            // LH
                                     : {{16{dw[15]}}, dw[15:0]};
            3'b010: load_val = dw;                                          // LW
            3'b100: load_val = (ba==0)?{24'd0,dw[7:0]}:(ba==1)?{24'd0,dw[15:8]}:
                               (ba==2)?{24'd0,dw[23:16]}:{24'd0,dw[31:24]}; // LBU
            3'b101: load_val = ba[1] ? {16'd0, dw[31:16]} : {16'd0, dw[15:0]}; // LHU
            default: load_val = dw;
        endcase
    end

    // ---- write-back value (non-load) ----
    localparam WB_ALU=2'b00, WB_MEM=2'b01, WB_PC4=2'b10, WB_IMM=2'b11;
    wire [31:0] pc_plus4 = pc + 32'd4;
    always @(*) begin
        case (wb_sel)
            WB_ALU : wb_data = alu_result;
            WB_MEM : wb_data = load_val;
            WB_PC4 : wb_data = pc_plus4;
            WB_IMM : wb_data = imm;
            default: wb_data = alu_result;
        endcase
    end

    // ---- branch / next-PC ----
    reg branch_cond;
    always @(*) case (funct3)
        3'b000 : branch_cond = (rs1_data == rs2_data);
        3'b001 : branch_cond = (rs1_data != rs2_data);
        3'b100 : branch_cond = ($signed(rs1_data) <  $signed(rs2_data));
        3'b101 : branch_cond = ($signed(rs1_data) >= $signed(rs2_data));
        3'b110 : branch_cond = (rs1_data <  rs2_data);
        3'b111 : branch_cond = (rs1_data >= rs2_data);
        default: branch_cond = 1'b0;
    endcase
    wire branch_taken = branch & branch_cond;
    wire [31:0] pc_target   = pc + imm;
    wire [31:0] jalr_target = {alu_result[31:1], 1'b0};
    wire trap_take = take_trap & in_exec;
    reg  [31:0] next_pc;
    always @(*) begin
        if      (trap_take)         next_pc = mtvec_out;
        else if (is_mret & in_exec) next_pc = mepc_out;
        else if (jalr)              next_pc = jalr_target;
        else if (jump)              next_pc = pc_target;
        else if (branch_taken)      next_pc = pc_target;
        else                        next_pc = pc_plus4;
    end

    wire mem_access = mem_read | mem_write;

    // ---- control FSM ----
    always @(posedge clk) begin
        if (rst) begin
            state <= S_FETCH;
            pc    <= RESET_PC;
        end else if (halt) begin
            state <= S_HALT;
        end else begin
            case (state)
                S_FETCH: state <= S_EXEC;
                S_EXEC: begin
                    if (take_trap) begin                 // trap: suppress, redirect
                        pc <= next_pc; state <= S_FETCH;
                    end else if (mem_access) begin        // load OR store -> MEM
                        state <= S_MEM;
                    end else begin                        // ALU/branch/jump/csr
                        pc <= next_pc; state <= S_FETCH;
                    end
                end
                S_MEM: if (dmem_ready) begin              // stall here until slave acks
                    pc <= next_pc; state <= S_FETCH;
                end
                default: state <= S_HALT;
            endcase
        end
    end

    // ---- register-file write enable ----
    always @(*) begin
        rf_we = 1'b0;
        if (state == S_EXEC && !take_trap && !mem_access)
            rf_we = is_csr ? 1'b1 : reg_write;            // ALU/jump/csr write-back
        else if (state == S_MEM && dmem_ready)
            rf_we = reg_write;                            // load write-back (when acked)
    end
endmodule

`default_nettype wire
