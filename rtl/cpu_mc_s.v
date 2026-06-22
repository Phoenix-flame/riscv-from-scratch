// =====================================================================
// cpu_mc_s.v  -  Multi-cycle RV32IM + Zicsr + M/S/U privilege & delegation
// ---------------------------------------------------------------------
// cpu_mc with supervisor mode added. Three things change versus the M/U
// core:
//   1. sret is decoded (SYSTEM, funct3=000, imm=0x102) and returns from an
//      S-mode trap, mirroring how mret returns from an M-mode trap.
//   2. CSR access is privilege-checked properly: a CSR's minimum privilege
//      is addr[9:8] (00=U,01=S,11=M), and the core must be at least that
//      privileged. mret needs M; sret needs >= S. A violation is an illegal
//      instruction.
//   3. The trap target is no longer always mtvec. csr_s decides per-trap
//      whether medeleg/mideleg sends it to S (stvec) instead, and this core
//      simply jumps wherever csr_s points.
// No MMU here -- the point of this step is the privilege/delegation
// machinery, demonstrated with ecall and an interrupt rather than paging.
// =====================================================================
`default_nettype none

module cpu_mc_s #(
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
    output wire [31:0] pc_out
);
    localparam S_FETCH=2'd0, S_EXEC=2'd1, S_MEM=2'd2, S_HALT=2'd3;
    localparam PRIV_M=2'b11, PRIV_S=2'b01;
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
    wire        is_sret   = is_system && (funct3==3'b000) && (instr[31:20]==12'h102);
    wire        is_ecall  = is_system && (funct3==3'b000) && (instr[31:20]==12'h000);
    wire        is_ebreak = is_system && (funct3==3'b000) && (instr[31:20]==12'h001);
    wire [11:0] csr_addr  = instr[31:20];
    wire [4:0]  zimm      = rs1_addr;
    wire [31:0] rs1_data, rs2_data;
    wire [31:0] csr_wsrc  = funct3[2] ? {27'b0, zimm} : rs1_data;

    wire        irq_pending;
    wire [31:0] irq_cause;
    wire [1:0]  cur_priv;
    wire [31:0] csr_rdata, trap_vector, mret_target, sret_target;

    wire op_known =
        (opcode==7'b0110011)||(opcode==7'b0010011)||(opcode==7'b0000011)||
        (opcode==7'b0100011)||(opcode==7'b1100011)||(opcode==7'b1101111)||
        (opcode==7'b1100111)||(opcode==7'b0110111)||(opcode==7'b0010111)||
        (opcode==7'b1110011)||(opcode==7'b0001111);

    // ---- privilege checks ----
    // CSR's minimum privilege is its address bits [9:8]; the core must be at
    // least that privileged (numeric compare works: M=11 > S=01 > U=00).
    wire [1:0] csr_min_priv = csr_addr[9:8];
    wire       csr_ok    = (cur_priv >= csr_min_priv);
    wire       bad_csr   = is_csr  & ~csr_ok;
    wire       bad_mret  = is_mret & (cur_priv != PRIV_M);
    wire       bad_sret  = is_sret & (cur_priv <  PRIV_S);
    wire       illegal_instr = ~op_known | bad_csr | bad_mret | bad_sret;

    wire exception = illegal_instr | is_ecall | is_ebreak;
    // Don't take an interrupt on an mret/sret: let the return retire first.
    wire take_trap = exception | (irq_pending & ~is_mret & ~is_sret);

    // ecall cause depends on the privilege it was issued from (U=8, S=9, M=11)
    wire [31:0] ecall_cause = (cur_priv==2'b00) ? 32'd8 :
                              (cur_priv==PRIV_S) ? 32'd9 : 32'd11;
    wire [31:0] trap_cause = illegal_instr ? 32'd2  :
                             is_ecall       ? ecall_cause :
                             is_ebreak      ? 32'd3  :
                                              irq_cause;
    // mtval/stval: faulting instruction for illegal, PC for ebreak, else 0
    wire [31:0] trap_val   = illegal_instr ? instr :
                             is_ebreak      ? pc    : 32'd0;

    csr_s u_csr (
        .clk(clk), .rst(rst),
        .csr_addr(csr_addr), .csr_funct3(funct3), .csr_wsrc(csr_wsrc),
        .csr_we(is_csr & in_exec & ~take_trap),
        .csr_rdata(csr_rdata),
        .pc(pc), .timer_irq(timer_irq), .ext_irq(ext_irq),
        .instr_is_mret(is_mret & in_exec & ~take_trap),
        .instr_is_sret(is_sret & in_exec & ~take_trap),
        .take_trap(take_trap & in_exec),
        .trap_cause(trap_cause), .trap_val(trap_val),
        .trap_vector(trap_vector), .mret_target(mret_target), .sret_target(sret_target),
        .irq_pending(irq_pending), .irq_cause(irq_cause), .deleg_now(),
        .cur_priv(cur_priv), .satp_out()
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

    // ---- data bus ----
    wire [1:0] ba = alu_result[1:0];
    assign dmem_addr  = alu_result;
    assign dmem_wdata = (funct3==3'b000) ? (rs2_data[7:0]  <<  (8*ba)) :
                        (funct3==3'b001) ? (rs2_data[15:0] << (8*ba)) :
                                            rs2_data;
    wire [3:0] wmask  = (funct3==3'b000) ? (4'b0001 << ba) :
                        (funct3==3'b001) ? (4'b0011 << ba) : 4'b1111;
    assign dmem_we = (in_exec & mem_write & ~take_trap) ? wmask : 4'b0000;
    assign dmem_re = mem_read & (in_exec | in_mem);

    // ---- load extraction ----
    wire [31:0] dw = dmem_rdata;
    reg  [31:0] load_val;
    always @(*) begin
        case (funct3)
            3'b000: case (ba)
                2'd0: load_val = {{24{dw[7]}},  dw[7:0]};
                2'd1: load_val = {{24{dw[15]}}, dw[15:8]};
                2'd2: load_val = {{24{dw[23]}}, dw[23:16]};
                default: load_val = {{24{dw[31]}}, dw[31:24]};
            endcase
            3'b001: load_val = ba[1] ? {{16{dw[31]}}, dw[31:16]} : {{16{dw[15]}}, dw[15:0]};
            3'b010: load_val = dw;
            3'b100: load_val = (ba==0)?{24'd0,dw[7:0]}:(ba==1)?{24'd0,dw[15:8]}:
                               (ba==2)?{24'd0,dw[23:16]}:{24'd0,dw[31:24]};
            3'b101: load_val = ba[1] ? {16'd0, dw[31:16]} : {16'd0, dw[15:0]};
            default: load_val = dw;
        endcase
    end

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
        if      (trap_take)          next_pc = trap_vector;   // mtvec or stvec (csr_s)
        else if (is_mret & in_exec)  next_pc = mret_target;
        else if (is_sret & in_exec)  next_pc = sret_target;
        else if (jalr)               next_pc = jalr_target;
        else if (jump)               next_pc = pc_target;
        else if (branch_taken)       next_pc = pc_target;
        else                         next_pc = pc_plus4;
    end

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
                    if (take_trap) begin
                        pc <= next_pc; state <= S_FETCH;
                    end else if (mem_read) begin
                        state <= S_MEM;
                    end else begin
                        pc <= next_pc; state <= S_FETCH;
                    end
                end
                S_MEM:  begin pc <= next_pc; state <= S_FETCH; end
                default: state <= S_HALT;
            endcase
        end
    end

    // ---- register-file write enable ----
    always @(*) begin
        rf_we = 1'b0;
        if (state == S_EXEC && !take_trap && !mem_read)
            rf_we = is_csr ? 1'b1 : reg_write;
        else if (state == S_MEM)
            rf_we = reg_write;
    end
endmodule

`default_nettype wire
