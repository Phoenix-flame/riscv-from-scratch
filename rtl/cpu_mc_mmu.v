// =====================================================================
// cpu_mc_mmu.v  -  Multi-cycle RV32IM + Zicsr + privilege + Sv32 MMU
//                  (synthesizable; works against registered block RAM)
// ---------------------------------------------------------------------
// This is cpu_mc with a *multi-cycle* page-table walker. The combinational
// MMU (mmu.v) can't run against block RAM (registered reads), so here the
// walk is sequenced through the normal data port over several cycles:
//
//   FETCH -> EXEC -> (memory access path) -> FETCH
//
//   memory access path:
//     no translation (M-mode or Sv32 off):   ACC -> [ACCD for loads]
//     translation on (U-mode + Sv32):
//         PTW1  : drive level-1 PTE address
//         PTW1D : level-1 PTE valid -> superpage leaf?  pointer?  fault?
//         PTW0D : level-0 PTE valid -> leaf?  fault?
//         ACC   : drive the translated physical address
//         ACCD  : (loads) capture data
//     any bad/insufficient PTE -> PF (raise a page-fault trap)
//
// The walker reuses the single data port (no extra RAM ports), which is
// how real hardware does it. Page tables live in RAM; the translated
// physical address can target RAM or any peripheral.
// =====================================================================
`default_nettype none

module cpu_mc_mmu #(
    parameter RESET_PC = 32'h0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        timer_irq,
    input  wire        halt,
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_rdata,
    output reg  [31:0] dmem_addr,
    output wire [3:0]  dmem_we,
    output wire [31:0] dmem_wdata,
    input  wire [31:0] dmem_rdata,
    output wire [31:0] pc_out
);
    localparam S_FETCH=4'd0, S_EXEC=4'd1, S_ACC=4'd2, S_ACCD=4'd3,
               S_PTW1=4'd4,  S_PTW1D=4'd5, S_PTW0D=4'd6, S_PF=4'd7, S_HALT=4'd8;
    reg [3:0]  state;
    reg [31:0] pc;
    reg [31:0] pa_reg;            // translated physical address
    reg        dpf, dpf_store;    // pending data page fault

    assign imem_addr = pc;
    assign pc_out    = pc;
    wire [31:0] instr = imem_rdata;

    // ---- decode ----
    wire [6:0] opcode  = instr[6:0];
    wire [4:0] rd_addr = instr[11:7];
    wire [2:0] funct3  = instr[14:12];
    wire [4:0] rs1_addr= instr[19:15];
    wire [4:0] rs2_addr= instr[24:20];
    wire [6:0] funct7  = instr[31:25];

    wire reg_write, alu_src_a, alu_src_b, mem_read, mem_write, branch, jump, jalr;
    wire [1:0] wb_sel; wire [2:0] imm_type; wire [4:0] alu_op;
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
    wire [31:0] csr_rdata, mtvec_out, mepc_out, satp_val;

    wire op_known =
        (opcode==7'b0110011)||(opcode==7'b0010011)||(opcode==7'b0000011)||
        (opcode==7'b0100011)||(opcode==7'b1100011)||(opcode==7'b1101111)||
        (opcode==7'b1100111)||(opcode==7'b0110111)||(opcode==7'b0010111)||
        (opcode==7'b1110011)||(opcode==7'b0001111);
    wire priv_violation = in_user & (is_mret | is_csr);
    wire illegal_instr  = ~op_known | priv_violation;

    wire exec_exc  = illegal_instr | is_ecall | is_ebreak;
    wire exec_trap = exec_exc | irq_pending;            // trap decided in EXEC
    wire in_exec   = (state == S_EXEC);
    wire in_pf     = (state == S_PF);

    wire        csr_take_trap = (exec_trap & in_exec) | in_pf;
    wire [31:0] exec_cause = illegal_instr ? 32'd2 :
                             is_ecall       ? (in_user ? 32'd8 : 32'd11) :
                             is_ebreak      ? 32'd3 : 32'h8000_0007;
    wire [31:0] trap_cause = in_pf ? (dpf_store ? 32'd15 : 32'd13) : exec_cause;

    csr u_csr (
        .clk(clk), .rst(rst),
        .csr_addr(csr_addr), .csr_funct3(funct3), .csr_wsrc(csr_wsrc),
        .csr_we(is_csr & in_exec & ~exec_trap),
        .csr_rdata(csr_rdata),
        .pc(pc), .timer_irq(timer_irq), .ext_irq(1'b0),
        .instr_is_mret(is_mret & in_exec & ~exec_trap),
        .take_trap(csr_take_trap), .trap_cause(trap_cause),
        .mtvec_out(mtvec_out), .mepc_out(mepc_out), .irq_pending(irq_pending),
        .cur_priv(cur_priv), .satp_out(satp_val)
    );

    // ---- register file ----
    reg  [31:0] wb_data; reg rf_we;
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
    wire [31:0] alu_result; wire alu_zero;
    alu u_alu (.a(alu_a), .b(alu_b), .alu_op(alu_op),
               .result(alu_result), .zero(alu_zero));

    // ---- Sv32 translation (multi-cycle walk) ----
    wire        xlate_active = in_user && satp_val[31];
    wire [9:0]  vpn1 = alu_result[31:22];
    wire [9:0]  vpn0 = alu_result[21:12];
    wire [31:0] pte1_addr = {satp_val[21:0],12'b0} + {20'b0, vpn1, 2'b0};
    wire [31:0] pte = dmem_rdata;          // a PTE arrives on the data port
    wire        pte_v = pte[0], pte_r = pte[1], pte_w = pte[2], pte_x = pte[3], pte_u = pte[4];
    wire        pte_leaf = pte_r | pte_x;
    wire        pte_bad  = ~pte_v | (~pte_r & pte_w);
    wire [31:0] pte0_addr = {pte[31:10],12'b0} + {20'b0, vpn0, 2'b0};
    wire [31:0] pa_super  = {pte[31:20], alu_result[21:0]};   // 4 MiB
    wire [31:0] pa_4k     = {pte[31:10], alu_result[11:0]};   // 4 KiB
    wire        perm_ok   = pte_u & ((mem_read & pte_r) | (mem_write & pte_w));
    wire [31:0] mem_pa    = xlate_active ? pa_reg : alu_result;

    // ---- data-bus address per state ----
    wire [1:0] ba = alu_result[1:0];
    always @(*) begin
        case (state)
            S_PTW1:        dmem_addr = pte1_addr;
            // only descend to a level-0 PTE when the level-1 PTE is a
            // non-leaf pointer; otherwise the address (from the leaf PPN)
            // could point at a combinational peripheral and form a comb
            // loop. Page tables always live in RAM, so this stays in RAM.
            S_PTW1D:       dmem_addr = (pte_bad | pte_leaf) ? pte1_addr : pte0_addr;
            S_ACC, S_ACCD: dmem_addr = mem_pa;
            default:       dmem_addr = alu_result;
        endcase
    end
    assign dmem_wdata = (funct3==3'b000) ? (rs2_data[7:0]  << (8*ba)) :
                        (funct3==3'b001) ? (rs2_data[15:0] << (8*ba)) : rs2_data;
    wire [3:0] wmask  = (funct3==3'b000) ? (4'b0001 << ba) :
                        (funct3==3'b001) ? (4'b0011 << ba) : 4'b1111;
    assign dmem_we = ((state==S_ACC) & mem_write) ? wmask : 4'b0000;

    // ---- load extraction (valid in S_ACCD) ----
    wire [31:0] dw = dmem_rdata;
    reg [31:0] load_val;
    always @(*) begin
        case (funct3)
            3'b000: case (ba)
                2'd0: load_val={{24{dw[7]}},dw[7:0]};   2'd1: load_val={{24{dw[15]}},dw[15:8]};
                2'd2: load_val={{24{dw[23]}},dw[23:16]}; default: load_val={{24{dw[31]}},dw[31:24]};
            endcase
            3'b001: load_val = ba[1] ? {{16{dw[31]}},dw[31:16]} : {{16{dw[15]}},dw[15:0]};
            3'b010: load_val = dw;
            3'b100: load_val = (ba==0)?{24'd0,dw[7:0]}:(ba==1)?{24'd0,dw[15:8]}:
                               (ba==2)?{24'd0,dw[23:16]}:{24'd0,dw[31:24]};
            3'b101: load_val = ba[1] ? {16'd0,dw[31:16]} : {16'd0,dw[15:0]};
            default: load_val = dw;
        endcase
    end

    localparam WB_ALU=2'b00, WB_MEM=2'b01, WB_PC4=2'b10, WB_IMM=2'b11;
    wire [31:0] pc_plus4 = pc + 32'd4;
    always @(*) case (wb_sel)
        WB_ALU: wb_data = alu_result;  WB_MEM: wb_data = load_val;
        WB_PC4: wb_data = pc_plus4;    WB_IMM: wb_data = imm;
        default: wb_data = alu_result;
    endcase

    // ---- branch / next-pc (non-memory) ----
    reg branch_cond;
    always @(*) case (funct3)
        3'b000: branch_cond=(rs1_data==rs2_data);  3'b001: branch_cond=(rs1_data!=rs2_data);
        3'b100: branch_cond=($signed(rs1_data)<$signed(rs2_data));
        3'b101: branch_cond=($signed(rs1_data)>=$signed(rs2_data));
        3'b110: branch_cond=(rs1_data<rs2_data);   3'b111: branch_cond=(rs1_data>=rs2_data);
        default: branch_cond=1'b0;
    endcase
    wire branch_taken = branch & branch_cond;
    wire [31:0] pc_target = pc + imm;
    wire [31:0] jalr_target = {alu_result[31:1],1'b0};
    reg [31:0] exec_next_pc;
    always @(*) begin
        if      (exec_trap)    exec_next_pc = mtvec_out;
        else if (is_mret)      exec_next_pc = mepc_out;
        else if (jalr)         exec_next_pc = jalr_target;
        else if (jump)         exec_next_pc = pc_target;
        else if (branch_taken) exec_next_pc = pc_target;
        else                   exec_next_pc = pc_plus4;
    end

    wire is_mem = mem_read | mem_write;

    // ---- FSM ----
    always @(posedge clk) begin
        if (rst) begin
            state <= S_FETCH; pc <= RESET_PC; dpf <= 1'b0; dpf_store <= 1'b0;
        end else if (halt) begin
            state <= S_HALT;
        end else begin
            case (state)
                S_FETCH: state <= S_EXEC;
                S_EXEC: begin
                    if (exec_trap) begin
                        pc <= exec_next_pc; state <= S_FETCH;         // irq/illegal/ecall
                    end else if (is_mem) begin
                        if (xlate_active) state <= S_PTW1;            // translate
                        else              state <= S_ACC;            // physical
                    end else begin
                        pc <= exec_next_pc; state <= S_FETCH;         // alu/branch/csr/mret
                    end
                end
                S_PTW1:  state <= S_PTW1D;                            // wait level-1 read
                S_PTW1D: begin
                    if (pte_bad)            begin dpf<=1; dpf_store<=mem_write; state<=S_PF; end
                    else if (pte_leaf) begin                          // superpage
                        if (!perm_ok)       begin dpf<=1; dpf_store<=mem_write; state<=S_PF; end
                        else begin pa_reg <= pa_super; state <= S_ACC; end
                    end else                state <= S_PTW0D;         // descend (read posted)
                end
                S_PTW0D: begin
                    if (pte_bad | ~pte_leaf) begin dpf<=1; dpf_store<=mem_write; state<=S_PF; end
                    else if (!perm_ok)       begin dpf<=1; dpf_store<=mem_write; state<=S_PF; end
                    else begin pa_reg <= pa_4k; state <= S_ACC; end
                end
                S_ACC: begin
                    if (mem_read) state <= S_ACCD;                    // wait load data
                    else begin pc <= pc_plus4; state <= S_FETCH; end  // store done
                end
                S_ACCD: begin pc <= pc_plus4; state <= S_FETCH; end   // load written back
                S_PF:   begin pc <= mtvec_out; dpf<=0; state <= S_FETCH; end
                default: state <= S_HALT;
            endcase
        end
    end

    // ---- register-file write enable ----
    always @(*) begin
        rf_we = 1'b0;
        if (state==S_EXEC && !exec_trap && !is_mem)
            rf_we = is_csr ? 1'b1 : reg_write;
        else if (state==S_ACCD)
            rf_we = reg_write;
    end
endmodule

`default_nettype wire
