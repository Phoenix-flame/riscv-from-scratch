// =====================================================================
// cpu_mc_c.v  -  Multi-cycle RV32IMC + Zicsr core (compressed instructions)
// ---------------------------------------------------------------------
// cpu_mc with the C extension. Because every RVC instruction expands 1:1 to
// a base instruction (rvc_expand.v), the decoder/ALU/CSR datapath is byte-
// for-byte the same as cpu_mc. What changes is *fetch*:
//
//   * The PC is halfword-aligned: instructions may start at any multiple
//     of 2, and sequential advance is +2 (compressed) or +4 (full).
//   * The instruction ROM is still a 32-bit word memory. An instruction at
//     pc[1]==0 lives entirely in one word. A compressed instruction at
//     pc[1]==1 lives in the high half of one word. But a *32-bit*
//     instruction at pc[1]==1 STRADDLES two words: its low half is the high
//     half of word N, its high half is the low half of word N+1.
//
// The straddle costs one extra cycle: the EXEC that discovers the
// instruction is 32-bit-at-odd-halfword latches the low half and -- in the
// same cycle -- presents word N+1's address to the ROM, so the second word
// is ready on the next cycle and execution proceeds:
//
//   FETCH -> EXEC(aligned or compressed: execute) ........... 2-3 cycles
//   FETCH -> EXEC(straddle found) -> EXEC(execute) .......... 3-4 cycles
//
// The discovery EXEC commits nothing -- all side effects (regfile, CSR,
// stores, traps) are gated off, because the decoded "instruction" in that
// cycle is half ours and half our neighbour's.
//
// Link addresses use pc + ilen (2 or 4), so c.jal/c.jalr correctly write
// pc+2 to ra. jalr still clears bit 0 only; mepc keeps bit 1 (IALIGN=16).
// =====================================================================
`default_nettype none

module cpu_mc_c #(
    parameter RESET_PC = 32'h0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        timer_irq,
    input  wire        ext_irq,
    input  wire        halt,
    // instruction ROM (synchronous read, 32-bit words)
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_rdata,
    // data bus
    output wire [31:0] dmem_addr,
    output wire [3:0]  dmem_we,
    output wire        dmem_re,
    output wire [31:0] dmem_wdata,
    input  wire [31:0] dmem_rdata,
    output wire [31:0] pc_out
);
    localparam S_FETCH=3'd0, S_EXEC=3'd1, S_MEM=3'd2, S_HALT=3'd3;
    reg [2:0]  state;
    reg [31:0] pc;

    // ---- halfword-aligned fetch ----
    reg         straddle_q;                  // executing a word-straddling instr
    reg  [15:0] lo_half;                     // its low 16 bits (from word N)

    wire [31:0] pc_word = {pc[31:2], 2'b00};
    // The cycle that *discovers* a straddle (need_hi, below) is also the
    // address-setup cycle for word N+1: present it immediately, so the ROM's
    // registered read has the second word ready on the very next cycle. The
    // straddle then costs one extra cycle, not two.
    wire        fetch_hi_now;
    assign imem_addr = (straddle_q | fetch_hi_now) ? (pc_word + 32'd4) : pc_word;
    assign pc_out    = pc;

    // the halfword our PC points at (meaningful only when ~straddle_q)
    wire [15:0] raw16   = pc[1] ? imem_rdata[31:16] : imem_rdata[15:0];
    wire        is_c    = ~straddle_q & (raw16[1:0] != 2'b11);
    wire        need_hi = ~straddle_q & pc[1] & (raw16[1:0] == 2'b11);

    wire [31:0] c_expanded;
    wire        c_illegal;
    rvc_expand u_rvc (.c(raw16), .instr32(c_expanded), .illegal(c_illegal));

    wire [31:0] instr = straddle_q ? {imem_rdata[15:0], lo_half} :
                        is_c       ? c_expanded :
                                     imem_rdata;

    wire in_exec = (state == S_EXEC);
    wire in_mem  = (state == S_MEM);
    assign fetch_hi_now = in_exec & need_hi;
    // an EXEC cycle that is actually executing (not the straddle discovery)
    wire commit  = in_exec & ~need_hi;

    // ---- decode (identical to cpu_mc, fed the expanded instruction) ----
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
    // compressed: trust the expander's legality; full: the usual opcode check
    wire illegal_instr  = (is_c ? c_illegal : ~op_known) | priv_violation;

    wire exception = illegal_instr | is_ecall | is_ebreak;
    wire take_trap = exception | (irq_pending & ~is_mret);

    wire [31:0] trap_cause = illegal_instr ? 32'd2  :
                             is_ecall       ? (in_user ? 32'd8 : 32'd11) :
                             is_ebreak      ? 32'd3  :
                                              irq_cause;

    // CSR state advances only on a real commit cycle (never on discovery)
    csr u_csr (
        .clk(clk), .rst(rst),
        .csr_addr(csr_addr), .csr_funct3(funct3), .csr_wsrc(csr_wsrc),
        .csr_we(is_csr & commit & ~take_trap),
        .csr_rdata(csr_rdata),
        .pc(pc), .timer_irq(timer_irq), .ext_irq(ext_irq),
        .instr_is_mret(is_mret & commit & ~take_trap),
        .take_trap(take_trap & commit),
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

    // ---- data bus ----
    wire [1:0] ba = alu_result[1:0];
    assign dmem_addr  = alu_result;
    assign dmem_wdata = (funct3==3'b000) ? (rs2_data[7:0]  <<  (8*ba)) :
                        (funct3==3'b001) ? (rs2_data[15:0] << (8*ba)) :
                                            rs2_data;
    wire [3:0] wmask  = (funct3==3'b000) ? (4'b0001 << ba) :
                        (funct3==3'b001) ? (4'b0011 << ba) :
                                            4'b1111;
    assign dmem_we = (commit & mem_write & ~take_trap) ? wmask : 4'b0000;
    assign dmem_re = mem_read & (commit | in_mem);

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
            3'b001: load_val = ba[1] ? {{16{dw[31]}}, dw[31:16]}
                                     : {{16{dw[15]}}, dw[15:0]};
            3'b010: load_val = dw;
            3'b100: load_val = (ba==0)?{24'd0,dw[7:0]}:(ba==1)?{24'd0,dw[15:8]}:
                               (ba==2)?{24'd0,dw[23:16]}:{24'd0,dw[31:24]};
            3'b101: load_val = ba[1] ? {16'd0, dw[31:16]} : {16'd0, dw[15:0]};
            default: load_val = dw;
        endcase
    end

    // ---- write-back value: link is pc + instruction length, not pc + 4 ----
    localparam WB_ALU=2'b00, WB_MEM=2'b01, WB_PC4=2'b10, WB_IMM=2'b11;
    wire [31:0] pc_nexti = pc + (is_c ? 32'd2 : 32'd4);  // c.jal/c.jalr link = pc+2
    always @(*) begin
        case (wb_sel)
            WB_ALU : wb_data = alu_result;
            WB_MEM : wb_data = load_val;
            WB_PC4 : wb_data = pc_nexti;
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
    wire [31:0] pc_target   = pc + imm;          // RVC offsets ride in the expansion
    wire [31:0] jalr_target = {alu_result[31:1], 1'b0};  // clear bit 0 only (IALIGN=16)
    wire trap_take = take_trap & commit;
    reg  [31:0] next_pc;
    always @(*) begin
        if      (trap_take)         next_pc = mtvec_out;
        else if (is_mret & commit)  next_pc = mepc_out;
        else if (jalr)              next_pc = jalr_target;
        else if (jump)              next_pc = pc_target;
        else if (branch_taken)      next_pc = pc_target;
        else                        next_pc = pc_nexti;
    end

    // ---- the control FSM (cpu_mc plus the straddle detour) ----
    always @(posedge clk) begin
        if (rst) begin
            state      <= S_FETCH;
            pc         <= RESET_PC;
            straddle_q <= 1'b0;
        end else if (halt) begin
            state <= S_HALT;
        end else begin
            case (state)
                S_FETCH:  state <= S_EXEC;        // wait for ROM word N
                S_EXEC: begin
                    if (need_hi) begin            // 32-bit instr at pc[1]==1:
                        lo_half    <= imem_rdata[31:16];   // keep its low half;
                        straddle_q <= 1'b1;       // word N+1 is already being
                        state      <= S_EXEC;     // read -- execute next cycle
                    end else if (take_trap) begin
                        pc <= next_pc; straddle_q <= 1'b0; state <= S_FETCH;
                    end else if (mem_read) begin
                        state <= S_MEM;
                    end else begin
                        pc <= next_pc; straddle_q <= 1'b0; state <= S_FETCH;
                    end
                end
                S_MEM:  begin pc <= next_pc; straddle_q <= 1'b0; state <= S_FETCH; end
                default: state <= S_HALT;
            endcase
        end
    end

    // ---- register-file write enable per state ----
    always @(*) begin
        rf_we = 1'b0;
        if (state == S_EXEC && !need_hi && !take_trap && !mem_read)
            rf_we = is_csr ? 1'b1 : reg_write;
        else if (state == S_MEM)
            rf_we = reg_write;
    end
endmodule

`default_nettype wire
