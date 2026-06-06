// =====================================================================
// cpu_core_dbg.v  -  cpu_core + a hardware debug interface
// ---------------------------------------------------------------------
// Adds the primitives a gdb/JTAG debug stub needs, driven by an external
// debug module:
//   * halt on request, resume, single-step
//   * NBP hardware PC breakpoints (halt before executing the matched insn)
//   * read/write any GPR and the PC while halted
//   * the data bus is freed while halted so the debug module can read/write
//     memory through it (handled at the SoC level)
// Everything outside the debug hooks is identical to cpu_core.
// =====================================================================
`default_nettype none

module cpu_core_dbg #(
    parameter INIT_FILE  = "",
    parameter IMEM_WORDS = 1024,
    parameter RESET_PC   = 32'h0000_0000,
    parameter NBP        = 4
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        timer_irq,
    output wire [31:0] pc_out,
    output wire [31:0] instr_out,
    // data-memory bus master
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire        dmem_we,
    output wire [2:0]  dmem_funct3,
    input  wire [31:0] dmem_rdata,
    // ---- debug interface (driven by the debug module) ----
    input  wire             dbg_halt_req,    // request halt (level)
    input  wire             dbg_resume,      // 1-cycle pulse
    input  wire             dbg_step,        // 1-cycle pulse
    output wire             dbg_halted,
    output wire [31:0]      dbg_pc,
    input  wire             dbg_pc_we,
    input  wire [31:0]      dbg_pc_wdata,
    input  wire [4:0]       dbg_reg_addr,
    output wire [31:0]      dbg_reg_rdata,
    input  wire             dbg_reg_we,
    input  wire [31:0]      dbg_reg_wdata,
    input  wire [NBP-1:0]   bp_en,
    input  wire [NBP*32-1:0] bp_addr_flat
);
    // ---- Program counter -------------------------------------------
    reg  [31:0] pc;
    wire [31:0] pc_plus4 = pc + 32'd4;
    reg  [31:0] next_pc;

    // ---- debug halt FSM --------------------------------------------
    reg  halted, step_mode, skip_bp;
    integer bi;
    reg  bp_match;
    always @(*) begin
        bp_match = 1'b0;
        for (bi = 0; bi < NBP; bi = bi + 1)
            if (bp_en[bi] && (pc == bp_addr_flat[bi*32 +: 32])) bp_match = 1'b1;
    end
    wire bp_hit   = bp_match & ~skip_bp;
    wire halt_now = bp_hit | dbg_halt_req;          // assert while running
    wire run      = ~halted & ~halt_now;            // commit an instruction this cycle?

    always @(posedge clk) begin
        if (rst) begin halted <= 1'b0; step_mode <= 1'b0; skip_bp <= 1'b0; end
        else begin
            skip_bp <= 1'b0;                        // lasts exactly one cycle after resume/step
            if (halted) begin
                if (dbg_step)        begin halted <= 1'b0; step_mode <= 1'b1; skip_bp <= 1'b1; end
                else if (dbg_resume) begin halted <= 1'b0; step_mode <= 1'b0; skip_bp <= 1'b1; end
            end else begin
                if (run && step_mode) begin halted <= 1'b1; step_mode <= 1'b0; end  // one step done
                else if (halt_now)    halted <= 1'b1;                                // halt/bp
            end
        end
    end
    assign dbg_halted = halted;
    assign dbg_pc     = pc;

    always @(posedge clk) begin
        if (rst)             pc <= RESET_PC;
        else if (dbg_pc_we)  pc <= dbg_pc_wdata;    // gdb set $pc (only meaningful when halted)
        else if (run)        pc <= next_pc;
        // else hold (halted)
    end
    assign pc_out = pc;

    // ---- Fetch ------------------------------------------------------
    wire [31:0] instr;
    assign instr_out = instr;
    imem #(.WORDS(IMEM_WORDS), .INIT_FILE(INIT_FILE)) u_imem (.addr(pc), .instr(instr));

    // ---- Decode fields ---------------------------------------------
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

    // ---- CSR / trap decode -----------------------------------------
    wire        is_system = (opcode == 7'b1110011);
    wire        is_csr    = is_system && (funct3 != 3'b000);
    wire        is_mret   = is_system && (funct3==3'b000) && (instr[31:20]==12'h302);
    wire        is_ecall  = is_system && (funct3==3'b000) && (instr[31:20]==12'h000);
    wire        is_ebreak = is_system && (funct3==3'b000) && (instr[31:20]==12'h001);
    wire [11:0] csr_addr  = instr[31:20];
    wire [4:0]  zimm      = rs1_addr;
    wire [31:0] rs1_data, rs2_data;
    wire [31:0] csr_wsrc  = funct3[2] ? {27'b0, zimm} : rs1_data;

    wire        irq_pending; wire [1:0] cur_priv;
    wire        in_user = (cur_priv == 2'b00);
    wire [31:0] csr_rdata, mtvec_out, mepc_out;

    wire op_known =
        (opcode==7'b0110011)||(opcode==7'b0010011)||(opcode==7'b0000011)||
        (opcode==7'b0100011)||(opcode==7'b1100011)||(opcode==7'b1101111)||
        (opcode==7'b1100111)||(opcode==7'b0110111)||(opcode==7'b0010111)||
        (opcode==7'b1110011)||(opcode==7'b0001111)||(opcode==7'b0101111);
    wire priv_violation = in_user & (is_mret | is_csr);
    wire illegal_instr  = ~op_known | priv_violation;

    wire exception = illegal_instr | is_ecall | is_ebreak;
    // a trap only fires on a cycle where the instruction actually runs
    wire take_trap = run & (exception | irq_pending);
    wire [31:0] trap_cause = illegal_instr ? 32'd2 :
                             is_ecall       ? (in_user ? 32'd8 : 32'd11) :
                             is_ebreak      ? 32'd3 : 32'h8000_0007;

    csr u_csr (
        .clk(clk), .rst(rst),
        .csr_addr(csr_addr), .csr_funct3(funct3), .csr_wsrc(csr_wsrc),
        .csr_we(run & is_csr & ~take_trap),
        .csr_rdata(csr_rdata),
        .pc(pc), .timer_irq(timer_irq), .ext_irq(1'b0),
        .instr_is_mret(run & is_mret & ~take_trap), .take_trap(take_trap),
        .trap_cause(trap_cause),
        .mtvec_out(mtvec_out), .mepc_out(mepc_out), .irq_pending(irq_pending),
        .cur_priv(cur_priv)
    );

    // ---- Register file (debug taps share the ports while halted) ----
    reg  [31:0] wb_data;
    wire        reg_write_eff = take_trap ? 1'b0 : (is_csr ? 1'b1 : reg_write);
    wire [31:0] wb_final = is_csr ? csr_rdata :
                           is_sc  ? {31'b0, ~sc_ok} : wb_data;

    wire [4:0]  rf_rs1  = halted ? dbg_reg_addr  : rs1_addr;
    wire        rf_we   = halted ? dbg_reg_we    : (run & reg_write_eff);
    wire [4:0]  rf_rd   = halted ? dbg_reg_addr  : rd_addr;
    wire [31:0] rf_wd   = halted ? dbg_reg_wdata : wb_final;
    regfile u_regfile (
        .clk(clk), .we(rf_we),
        .rs1_addr(rf_rs1), .rs2_addr(rs2_addr),
        .rd_addr(rf_rd),   .rd_data(rf_wd),
        .rs1_data(rs1_data), .rs2_data(rs2_data)
    );
    assign dbg_reg_rdata = rs1_data;                // valid while halted (rs1=dbg_reg_addr)

    // ---- ALU --------------------------------------------------------
    wire [31:0] alu_a = alu_src_a ? pc  : rs1_data;
    wire [31:0] alu_b = alu_src_b ? imm : rs2_data;
    wire [31:0] alu_result; wire alu_zero;
    alu u_alu (.a(alu_a), .b(alu_b), .alu_op(alu_op), .result(alu_result), .zero(alu_zero));

    // ---- Data bus master + atomics ---------------------------------
    wire [31:0] mem_rdata = dmem_rdata;
    wire        is_amo_op  = (opcode == 7'b0101111);
    wire [4:0]  amo_f5     = funct7[6:2];
    wire        is_lr      = is_amo_op & (amo_f5 == 5'b00010);
    wire        is_sc      = is_amo_op & (amo_f5 == 5'b00011);
    wire        is_amo_rmw = is_amo_op & ~is_lr & ~is_sc;
    reg [31:0] amo_alu;
    always @(*) begin
        case (amo_f5)
            5'b00001: amo_alu = rs2_data;
            5'b00000: amo_alu = mem_rdata + rs2_data;
            5'b00100: amo_alu = mem_rdata ^ rs2_data;
            5'b01100: amo_alu = mem_rdata & rs2_data;
            5'b01000: amo_alu = mem_rdata | rs2_data;
            5'b10000: amo_alu = ($signed(mem_rdata) < $signed(rs2_data)) ? mem_rdata : rs2_data;
            5'b10100: amo_alu = ($signed(mem_rdata) > $signed(rs2_data)) ? mem_rdata : rs2_data;
            5'b11000: amo_alu = (mem_rdata < rs2_data) ? mem_rdata : rs2_data;
            5'b11100: amo_alu = (mem_rdata > rs2_data) ? mem_rdata : rs2_data;
            default:  amo_alu = rs2_data;
        endcase
    end
    reg         resv_valid; reg [31:0] resv_addr;
    wire        sc_ok     = resv_valid & (resv_addr == rs1_data);
    wire        amo_store = is_amo_rmw | (is_sc & sc_ok);

    assign dmem_addr   = is_amo_op ? rs1_data : alu_result;
    assign dmem_wdata  = is_amo_rmw ? amo_alu : rs2_data;
    assign dmem_we     = run & (take_trap ? 1'b0 : (mem_write | amo_store));
    assign dmem_funct3 = is_amo_op ? 3'b010 : funct3;

    always @(posedge clk) begin
        if (rst)                            resv_valid <= 1'b0;
        else if (~run)                      resv_valid <= resv_valid;     // frozen while halted
        else if (take_trap)                 resv_valid <= 1'b0;
        else if (is_lr)                     begin resv_valid <= 1'b1; resv_addr <= rs1_data; end
        else if (is_sc | is_amo_rmw)        resv_valid <= 1'b0;
    end

    // ---- Branch / next-PC / write-back ------------------------------
    reg branch_cond;
    always @(*) case (funct3)
        3'b000: branch_cond=(rs1_data==rs2_data);  3'b001: branch_cond=(rs1_data!=rs2_data);
        3'b100: branch_cond=($signed(rs1_data)<$signed(rs2_data));
        3'b101: branch_cond=($signed(rs1_data)>=$signed(rs2_data));
        3'b110: branch_cond=(rs1_data<rs2_data);   3'b111: branch_cond=(rs1_data>=rs2_data);
        default: branch_cond=1'b0;
    endcase
    wire branch_taken = branch & branch_cond;
    wire [31:0] pc_target   = pc + imm;
    wire [31:0] jalr_target = {alu_result[31:1], 1'b0};
    always @(*) begin
        if      (take_trap)    next_pc = mtvec_out;
        else if (is_mret)      next_pc = mepc_out;
        else if (jalr)         next_pc = jalr_target;
        else if (jump)         next_pc = pc_target;
        else if (branch_taken) next_pc = pc_target;
        else                   next_pc = pc_plus4;
    end
    localparam WB_ALU=2'b00, WB_MEM=2'b01, WB_PC4=2'b10, WB_IMM=2'b11;
    always @(*) case (wb_sel)
        WB_ALU: wb_data=alu_result; WB_MEM: wb_data=mem_rdata;
        WB_PC4: wb_data=pc_plus4;   WB_IMM: wb_data=imm;
        default: wb_data=alu_result;
    endcase
endmodule

`default_nettype wire
