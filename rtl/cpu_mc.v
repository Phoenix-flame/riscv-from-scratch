// =====================================================================
// cpu_mc.v  -  Multi-cycle RV32IM + Zicsr + privilege core (BRAM-ready)
// ---------------------------------------------------------------------
// Synthesis-oriented sibling of the single-cycle cpu_core. Block RAM has
// a REGISTERED read (data valid one cycle after the address), so a true
// single-cycle design can't use it. This core sequences each instruction
// over a few cycles so memory reads are registered:
//
//   FETCH : present PC to the instruction ROM
//   EXEC  : instruction is valid -> decode, regs, ALU, branch, CSR/trap.
//           ALU/branch/jump/store: commit and go back to FETCH.
//           load: present the data address, go to MEM.
//   MEM   : load data is valid -> write back, go to FETCH.
//
// So ALU/branch/store take 2 cycles and loads take 3. Reuses the same
// alu / control / immgen / regfile / csr blocks as the single-cycle core.
// (No MMU here -- a translated walk needs a multi-cycle walker.)
// =====================================================================
`default_nettype none

module cpu_mc #(
    parameter RESET_PC = 32'h0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        timer_irq,
    input  wire        halt,                 // freeze (set by SYSCON)
    // instruction ROM (synchronous read)
    output wire [31:0] imem_addr,            // byte address (use [.. :2])
    input  wire [31:0] imem_rdata,
    // data bus: word address + byte-write mask; read is 1-cycle (registered)
    output wire [31:0] dmem_addr,            // byte address
    output wire [3:0]  dmem_we,
    output wire [31:0] dmem_wdata,
    input  wire [31:0] dmem_rdata,
    output wire [31:0] pc_out
);
    localparam S_FETCH=2'd0, S_EXEC=2'd1, S_MEM=2'd2, S_HALT=2'd3;
    reg [1:0]  state;
    reg [31:0] pc;

    assign imem_addr = pc;                   // ROM is addressed by the PC
    assign pc_out    = pc;
    wire [31:0] instr = imem_rdata;          // valid in EXEC / MEM (pc held)

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
    wire take_trap = exception | irq_pending;
    wire [31:0] trap_cause = illegal_instr ? 32'd2  :
                             is_ecall       ? (in_user ? 32'd8 : 32'd11) :
                             is_ebreak      ? 32'd3  :
                                              32'h8000_0007;

    // CSR state only advances when an instruction actually commits (EXEC).
    csr u_csr (
        .clk(clk), .rst(rst),
        .csr_addr(csr_addr), .csr_funct3(funct3), .csr_wsrc(csr_wsrc),
        .csr_we(is_csr & in_exec & ~take_trap),
        .csr_rdata(csr_rdata),
        .pc(pc), .timer_irq(timer_irq),
        .instr_is_mret(is_mret & in_exec & ~take_trap),
        .take_trap(take_trap & in_exec),
        .trap_cause(trap_cause),
        .mtvec_out(mtvec_out), .mepc_out(mepc_out), .irq_pending(irq_pending),
        .cur_priv(cur_priv)
    );

    // ---- register file (write gated to the commit cycle) ----
    reg  [31:0] wb_data;
    reg         rf_we;                       // driven by the FSM below
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

    // ---- data bus: word address + byte mask + aligned store data ----
    wire [1:0] ba = alu_result[1:0];
    assign dmem_addr  = alu_result;
    assign dmem_wdata = (funct3==3'b000) ? (rs2_data[7:0]  <<  (8*ba)) :     // SB
                        (funct3==3'b001) ? (rs2_data[15:0] << (8*ba)) :      // SH
                                            rs2_data;                        // SW
    wire [3:0] wmask  = (funct3==3'b000) ? (4'b0001 << ba) :                 // SB
                        (funct3==3'b001) ? (4'b0011 << ba) :                 // SH
                                            4'b1111;                         // SW
    // write only during EXEC of a store that isn't being trapped
    assign dmem_we = (in_exec & mem_write & ~take_trap) ? wmask : 4'b0000;

    // ---- load extraction from the registered word (valid in MEM) ----
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
            WB_MEM : wb_data = load_val;       // (used in MEM)
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
    reg  [31:0] next_pc;
    always @(*) begin
        if      (take_trap)    next_pc = mtvec_out;
        else if (is_mret)      next_pc = mepc_out;
        else if (jalr)         next_pc = jalr_target;
        else if (jump)         next_pc = pc_target;
        else if (branch_taken) next_pc = pc_target;
        else                   next_pc = pc_plus4;
    end

    // ---- the control FSM ----
    always @(posedge clk) begin
        if (rst) begin
            state <= S_FETCH;
            pc    <= RESET_PC;
        end else if (halt) begin
            state <= S_HALT;
        end else begin
            case (state)
                S_FETCH: state <= S_EXEC;           // wait for ROM read
                S_EXEC: begin
                    if (take_trap) begin            // trap: suppress, redirect
                        pc <= next_pc; state <= S_FETCH;
                    end else if (mem_read) begin     // load: go fetch data
                        state <= S_MEM;
                    end else begin                   // ALU/branch/jump/store/csr
                        pc <= next_pc; state <= S_FETCH;
                    end
                end
                S_MEM:  begin pc <= next_pc; state <= S_FETCH; end
                default: state <= S_HALT;
            endcase
        end
    end

    // ---- register-file write enable per state ----
    always @(*) begin
        rf_we = 1'b0;
        if (state == S_EXEC && !take_trap && !mem_read)
            rf_we = is_csr ? 1'b1 : reg_write;       // ALU/jump/csr write-back
        else if (state == S_MEM)
            rf_we = reg_write;                       // load write-back
    end
endmodule

`default_nettype wire
