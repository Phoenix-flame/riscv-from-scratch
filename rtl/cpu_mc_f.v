// =====================================================================
// cpu_mc_f.v  -  Multi-cycle RV32IMF core (integer core + F extension)
// ---------------------------------------------------------------------
// cpu_mc with the single-precision floating-point extension bolted on:
//   * a second register file (fregfile) for f0..f31,
//   * the fpu_f datapath behind a start/done handshake,
//   * fcsr (frm rounding mode + fflags accrued exceptions) at CSR 0x001-0x003,
//   * flw / fsw on the existing data bus,
//   * an S_FPU wait state so OP-FP instructions hold the pipeline until the
//     FPU (multi-cycle for div/sqrt) reports done.
//
// FP opcodes are decoded locally here -- the shared integer control unit is
// left untouched, exactly as the RVC core did. Result routing follows the
// FPU's `to_int`: compare / classify / fcvt.w[u].s / fmv.x.w write the integer
// file; everything else writes the float file. fcvt.s.w[u] and fmv.w.x read
// the integer file for rs1; all other FP sources come from the float file.
//
// FMA (fmadd/fmsub/fnmadd/fnmsub) and double precision (D) are not implemented
// here -- see the step doc for the honest scope discussion.
// =====================================================================
`default_nettype none

module cpu_mc_f #(
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
    localparam S_FETCH=3'd0, S_EXEC=3'd1, S_MEM=3'd2, S_HALT=3'd3, S_FPU=3'd4;
    reg [2:0]  state;
    reg [31:0] pc;

    assign imem_addr = pc;
    assign pc_out    = pc;
    wire [31:0] instr = imem_rdata;

    wire in_exec = (state == S_EXEC);
    wire in_mem  = (state == S_MEM);
    wire in_fpu  = (state == S_FPU);

    // ---- decode ----
    wire [6:0] opcode  = instr[6:0];
    wire [4:0] rd_addr = instr[11:7];
    wire [2:0] funct3  = instr[14:12];
    wire [4:0] rs1_addr= instr[19:15];
    wire [4:0] rs2_addr= instr[24:20];
    wire [6:0] funct7  = instr[31:25];

    // ---- F-extension opcode recognition ----
    wire is_flw  = (opcode == 7'b0000111) && (funct3 == 3'b010);
    wire is_fsw  = (opcode == 7'b0100111) && (funct3 == 3'b010);
    wire is_fpop = (opcode == 7'b1010011);
    wire is_fp   = is_flw | is_fsw | is_fpop;

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

    // immediate: override type for fsw (S) and flw (I); integer ops unchanged
    localparam IMM_I=3'b000, IMM_S=3'b001;
    wire [2:0] imm_type_eff = is_fsw ? IMM_S : (is_flw ? IMM_I : imm_type);
    wire [31:0] imm;
    immgen u_immgen (.instr(instr), .imm_type(imm_type_eff), .imm(imm));

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

    // fcsr lives here (not in the shared csr.v): frm + fflags at 0x001-0x003
    reg  [2:0] frm;
    reg  [4:0] fflags;
    wire fcsr_sel = is_csr && (csr_addr==12'h001 || csr_addr==12'h002 || csr_addr==12'h003);
    reg  [31:0] fcsr_rdata;
    always @(*) case (csr_addr)
        12'h001: fcsr_rdata = {27'd0, fflags};
        12'h002: fcsr_rdata = {29'd0, frm};
        default: fcsr_rdata = {24'd0, frm, fflags};      // 0x003 fcsr
    endcase
    reg [31:0] fcsr_new;
    always @(*) case (funct3[1:0])
        2'b01:   fcsr_new = csr_wsrc;                     // csrrw
        2'b10:   fcsr_new = fcsr_rdata | csr_wsrc;        // csrrs
        2'b11:   fcsr_new = fcsr_rdata & ~csr_wsrc;       // csrrc
        default: fcsr_new = fcsr_rdata;
    endcase

    wire        irq_pending;
    wire [31:0] irq_cause;
    wire [1:0]  cur_priv;
    wire        in_user = (cur_priv == 2'b00);
    wire [31:0] csr_rdata, mtvec_out, mepc_out;

    wire op_known =
        (opcode==7'b0110011)||(opcode==7'b0010011)||(opcode==7'b0000011)||
        (opcode==7'b0100011)||(opcode==7'b1100011)||(opcode==7'b1101111)||
        (opcode==7'b1100111)||(opcode==7'b0110111)||(opcode==7'b0010111)||
        (opcode==7'b1110011)||(opcode==7'b0001111)|| is_fp;
    wire priv_violation = in_user & (is_mret | is_csr);
    wire illegal_instr  = ~op_known | priv_violation;

    wire exception = illegal_instr | is_ecall | is_ebreak;
    wire take_trap = exception | (irq_pending & ~is_mret);
    wire [31:0] trap_cause = illegal_instr ? 32'd2  :
                             is_ecall       ? (in_user ? 32'd8 : 32'd11) :
                             is_ebreak      ? 32'd3  :
                                              irq_cause;

    // CSR write only for *non-fcsr* CSRs (fcsr handled locally below)
    csr u_csr (
        .clk(clk), .rst(rst),
        .csr_addr(csr_addr), .csr_funct3(funct3), .csr_wsrc(csr_wsrc),
        .csr_we(is_csr & ~fcsr_sel & in_exec & ~take_trap),
        .csr_rdata(csr_rdata),
        .pc(pc), .timer_irq(timer_irq), .ext_irq(ext_irq),
        .instr_is_mret(is_mret & in_exec & ~take_trap),
        .take_trap(take_trap & in_exec),
        .trap_cause(trap_cause),
        .mtvec_out(mtvec_out), .mepc_out(mepc_out),
        .irq_pending(irq_pending), .irq_cause(irq_cause), .cur_priv(cur_priv)
    );

    // ---- integer register file ----
    reg  [31:0] int_wb;
    reg         rf_we;
    regfile u_regfile (
        .clk(clk), .we(rf_we),
        .rs1_addr(rs1_addr), .rs2_addr(rs2_addr),
        .rd_addr(rd_addr),   .rd_data(int_wb),
        .rs1_data(rs1_data), .rs2_data(rs2_data)
    );

    // ---- float register file ----
    wire [31:0] frs1_data, frs2_data;
    reg  [31:0] frf_wb;
    reg         frf_we;
    fregfile u_fregfile (
        .clk(clk), .we(frf_we),
        .rs1_addr(rs1_addr), .rs2_addr(rs2_addr),
        .rd_addr(rd_addr),   .rd_data(frf_wb),
        .rs1_data(frs1_data), .rs2_data(frs2_data)
    );

    // ---- FPU ----
    function [3:0] dec_fpop;
        input [6:0] f7; input [4:0] r2; input [2:0] f3;
        case (f7)
            7'b0000000: dec_fpop=4'd0;
            7'b0000100: dec_fpop=4'd1;
            7'b0001000: dec_fpop=4'd2;
            7'b0001100: dec_fpop=4'd3;
            7'b0101100: dec_fpop=4'd4;
            7'b0010000: dec_fpop=4'd5;
            7'b0010100: dec_fpop=4'd6;
            7'b1010000: dec_fpop=4'd7;
            7'b1100000: dec_fpop=r2[0]?4'd9 :4'd8;     // fcvt.wu.s / fcvt.w.s
            7'b1101000: dec_fpop=r2[0]?4'd11:4'd10;    // fcvt.s.wu / fcvt.s.w
            7'b1110000: dec_fpop=(f3==3'b000)?4'd12:4'd14; // fmv.x.w / fclass
            7'b1111000: dec_fpop=4'd13;                // fmv.w.x
            default:    dec_fpop=4'd0;
        endcase
    endfunction
    wire [3:0] fpu_op = dec_fpop(funct7, rs2_addr, funct3);
    // rs1 comes from the integer file for fcvt.s.w[u] and fmv.w.x
    wire fp_rs1_int = is_fpop && ((funct7==7'b1101000)||(funct7==7'b1111000));
    wire [31:0] fpu_a = fp_rs1_int ? rs1_data : frs1_data;
    wire [31:0] fpu_b = frs2_data;
    wire [2:0]  eff_rm = (funct3==3'b111) ? frm : funct3;   // dynamic -> fcsr.frm

    wire        fpu_start = in_exec & is_fpop & ~take_trap;
    wire [31:0] fpu_result;
    wire        fpu_to_int, fpu_done, fpu_busy;
    wire [4:0]  fpu_flags;
    fpu_f u_fpu (
        .clk(clk), .rst(rst), .start(fpu_start),
        .op(fpu_op), .fmt3(funct3), .rm(eff_rm),
        .a(fpu_a), .b(fpu_b),
        .result(fpu_result), .to_int(fpu_to_int), .flags(fpu_flags),
        .done(fpu_done), .busy(fpu_busy)
    );

    // ---- ALU (integer path) ----
    wire [31:0] alu_a = alu_src_a ? pc  : rs1_data;
    wire [31:0] alu_b = alu_src_b ? imm : rs2_data;
    wire [31:0] alu_result;
    wire        alu_zero;
    alu u_alu (.a(alu_a), .b(alu_b), .alu_op(alu_op),
               .result(alu_result), .zero(alu_zero));

    // ---- data bus (shared by integer load/store and flw/fsw) ----
    wire [31:0] fp_addr  = rs1_data + imm;                 // flw/fsw effective addr
    wire [31:0] eff_addr = (is_flw|is_fsw) ? fp_addr : alu_result;
    wire [1:0]  ba       = eff_addr[1:0];
    assign dmem_addr  = eff_addr;
    assign dmem_wdata = is_fsw ? frs2_data :
                        (funct3==3'b000) ? (rs2_data[7:0]  << (8*ba)) :
                        (funct3==3'b001) ? (rs2_data[15:0] << (8*ba)) :
                                            rs2_data;
    wire [3:0] wmask  = (funct3==3'b000) ? (4'b0001 << ba) :
                        (funct3==3'b001) ? (4'b0011 << ba) : 4'b1111;
    assign dmem_we = (in_exec & ~take_trap) ?
                        (is_fsw ? 4'b1111 : (mem_write ? wmask : 4'b0000)) : 4'b0000;
    assign dmem_re = (mem_read | is_flw) & (in_exec | in_mem);

    // ---- load extraction (integer loads; flw takes the whole word) ----
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

    // ---- integer write-back value ----
    localparam WB_ALU=2'b00, WB_MEM=2'b01, WB_PC4=2'b10, WB_IMM=2'b11;
    wire [31:0] pc_plus4 = pc + 32'd4;
    reg  [31:0] wb_data;
    always @(*) begin
        case (wb_sel)
            WB_ALU : wb_data = alu_result;
            WB_MEM : wb_data = load_val;
            WB_PC4 : wb_data = pc_plus4;
            WB_IMM : wb_data = imm;
            default: wb_data = alu_result;
        endcase
    end
    // integer regfile data: CSR read / fcsr read / FP->int result / normal
    always @(*) begin
        if      (is_csr & fcsr_sel) int_wb = fcsr_rdata;
        else if (is_csr)            int_wb = csr_rdata;
        else if (in_fpu)            int_wb = fpu_result;
        else                        int_wb = wb_data;
    end
    // float regfile data: flw word in MEM, FPU result in S_FPU
    always @(*) frf_wb = is_flw ? load_val : fpu_result;

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

    // ---- control FSM ----
    always @(posedge clk) begin
        if (rst) begin
            state <= S_FETCH; pc <= RESET_PC;
        end else if (halt) begin
            state <= S_HALT;
        end else begin
            case (state)
                S_FETCH: state <= S_EXEC;
                S_EXEC: begin
                    if (take_trap)            begin pc <= next_pc; state <= S_FETCH; end
                    else if (is_fpop)         state <= S_FPU;       // run the FPU
                    else if (mem_read|is_flw) state <= S_MEM;       // data fetch
                    else                      begin pc <= next_pc; state <= S_FETCH; end
                end
                S_MEM:  begin pc <= next_pc; state <= S_FETCH; end
                S_FPU:  if (fpu_done) begin pc <= next_pc; state <= S_FETCH; end
                default: state <= S_HALT;
            endcase
        end
    end

    // ---- write enables ----
    always @(*) begin
        rf_we = 1'b0;
        if (state == S_EXEC && !take_trap && !mem_read && !is_flw && !is_fpop)
            rf_we = is_csr ? 1'b1 : reg_write;          // integer ALU/jump/csr
        else if (state == S_MEM && !is_flw)
            rf_we = reg_write;                          // integer load
        else if (in_fpu && fpu_done && fpu_to_int)
            rf_we = 1'b1;                               // FP -> integer reg
    end
    always @(*) begin
        frf_we = 1'b0;
        if (state == S_MEM && is_flw)        frf_we = 1'b1;   // flw
        else if (in_fpu && fpu_done && !fpu_to_int) frf_we = 1'b1; // FP -> float reg
    end

    // ---- fcsr update: CSR writes + FPU exception-flag accrual ----
    always @(posedge clk) begin
        if (rst) begin frm <= 3'd0; fflags <= 5'd0; end
        else begin
            if (fcsr_sel & in_exec & ~take_trap) begin
                case (csr_addr)
                    12'h001: fflags <= fcsr_new[4:0];
                    12'h002: frm    <= fcsr_new[2:0];
                    12'h003: begin frm <= fcsr_new[7:5]; fflags <= fcsr_new[4:0]; end
                    default: ;
                endcase
            end else if (in_fpu & fpu_done) begin
                fflags <= fflags | fpu_flags;
            end
        end
    end
endmodule

`default_nettype wire
