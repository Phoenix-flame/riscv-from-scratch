// =====================================================================
// cpu_pipe_u.v  -  the UNIFIED pipelined core
//                  5-stage RV32IMA + Zicsr, M/S/U privilege with trap
//                  delegation, Sv32 MMU with translated fetch + I/D TLBs,
//                  BTB + 2-bit branch predictor, stall-capable buses
// ---------------------------------------------------------------------
// cpu_pipe_trap (Step 20) is the fast core, but it only had RV32IM, machine
// mode and two ideal combinational memories. The features added since
// lived on the multi-cycle cores: atomics (Step 26, single-cycle), user
// mode (21), the MMU (22/24) and the TLBs with fetch translation (41) --
// and, folded in by Step 44, supervisor mode with medeleg/mideleg (39) and
// the branch predictor (32). This core puts them all in the pipeline:
//
//   IF   predict the next PC (BTB + BHT), translate the PC (I-TLB),
//        fetch through a ready/valid I-port
//   ID   decode (+ AMO / LR / SC / sfence.vma / sret)
//   EX   ALU, branches, CSRs, translate the data address (D-TLB) and
//        COMMIT every trap -- so page faults are as precise as ecall
//   MEM  one request on a ready/valid D-port (two for an AMO:
//        read, then write the combined value); LR/SC reservation
//   WB   write back
//
// Stall-capable buses. Both ports complete in the cycle `req & ready`,
// with read data valid in that same cycle. Ideal memory ties ready=1; a
// cache answers ready=1 on a hit and holds it low through a refill
// (Step 43). That is what makes caches pluggable:
//   * I-port not ready -> IF inserts a bubble, the rest of the pipe moves
//   * D-port not ready -> the whole pipe freezes until it is
//
// Privilege (Step 44). csr_s supplies M/S/U, sstatus/sie/sip/stvec/sepc/
// scause/stval, and the delegation decision: a trap taken below M whose
// cause is set in medeleg (exceptions) or mideleg (interrupts) vectors to
// stvec in S-mode instead of mtvec. mtval/stval get the faulting address
// (page faults), the instruction (illegal) or the PC (ebreak, fetch fault).
//
// Branch prediction (Step 44, BPRED=1). IF steers the next PC with the
// branch_predictor of Step 32; the guess rides down the pipe and EX
// checks it: a wrong direction, a wrong target, or a "taken" guess on an
// instruction that is not a branch at all redirects to the true next PC.
// Only mispredictions flush. The predictor is indexed by VIRTUAL PC; a
// stale entry after an address-space switch is just a misprediction.
//
// Configurable (Step 45). Every feature is a parameter, and a feature that
// is off is not built: M_EXT=0 removes the multiplier/divider (MUL/DIV
// decode as illegal), A_EXT=0 the atomics, MMU=0 the TLBs and the walker
// (satp reads 0), HAS_S=0 / HAS_U=0 supervisor / user mode, BPRED=0 the
// predictor. tools/rvgen sets them from a Kconfig .config; all default
// on, which is the core of Steps 42-44.
//
// Translation. With satp.MODE=1 in S- or U-mode, IF looks up the I-TLB with
// the PC and EX looks up the D-TLB with the effective address; a hit
// costs nothing. A miss asks the shared walker (ptw.v), which borrows
// the D-port: a data miss holds EX (bubbles go into MEM) until the fill
// lands; a fetch miss just starves IF. A fetch fault travels down the
// pipe as a NOP tagged `ifault` and traps when it reaches EX; a data
// fault traps in EX directly. Either way the older instructions have
// already left EX, and the younger ones are flushed.
//
// Freeze discipline. Anything that commits in EX (traps, CSR writes,
// mret, sfence.vma, redirects) is gated by `ex_go`, so a frozen or held
// instruction commits exactly once, on the cycle it actually leaves EX.
// While EX is held its operands are re-latched every cycle from the
// forwarding network, so a producer that retires meanwhile is not lost.
// =====================================================================
`default_nettype none

module cpu_pipe_u #(
    parameter RESET_PC    = 32'h0,
    parameter TLB_ENTRIES = 4,        // per TLB
    parameter BPRED       = 1,        // 1 = BTB + 2-bit predictor, 0 = not-taken
    parameter BP_IDX_BITS = 6,        // predictor tables: 2**BP_IDX_BITS entries
    parameter M_EXT       = 1,        // RV32M multiply/divide
    parameter A_EXT       = 1,        // RV32A atomics
    parameter HAS_U       = 1,        // user mode
    parameter HAS_S       = 1,        // supervisor mode + delegation (needs HAS_U)
    parameter MMU         = 1         // Sv32 + TLBs + walker (needs HAS_U)
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        timer_irq,
    input  wire        halt,          // freeze (SoC halt register)

    // ---- instruction port ----
    output wire [31:0] i_addr,        // physical
    output wire        i_req,
    input  wire [31:0] i_rdata,
    input  wire        i_ready,

    // ---- data port (word, byte-lane write mask) ----
    output wire [31:0] d_addr,        // physical
    output wire        d_req,
    output wire [3:0]  d_we,          // 0 = read
    output wire [31:0] d_wdata,
    input  wire [31:0] d_rdata,
    input  wire        d_ready,

    output wire [31:0] pc_out,
    output wire        retire         // an instruction left WB this cycle
);
    localparam NOP = 32'h00000013;
    localparam WB_ALU=2'b00, WB_MEM=2'b01, WB_PC4=2'b10, WB_IMM=2'b11;

    // ---- cross-stage control ----
    wire        freeze;               // MEM is waiting on the D-port
    wire        ex_hold;              // EX is waiting on a data-side walk
    wire        ex_go;                // the instruction in EX leaves EX now
    wire        redirect;             // (only ever with ex_go)
    wire [31:0] redirect_pc;
    wire        load_use;
    wire        take_trap;
    wire        flush = redirect;

    wire [1:0]  cur_priv;
    wire [31:0] satp_val;
    wire        st_sum, st_mxr;            // mstatus.SUM / MXR
    wire        in_user = (cur_priv == 2'b00);
    wire        in_m    = (cur_priv == 2'b11);
    wire        vm_on   = (MMU != 0) & ~in_m & satp_val[31];   // S and U are translated

    // ---- walker <-> TLB plumbing (driven further down) ----
    wire        ptw_busy, ptw_fill, ptw_fault, ptw_side_i, ptw_super;
    wire [31:0] ptw_va, ptw_addr;
    wire [21:0] ptw_ppn;
    wire [3:0]  ptw_perm;
    // last walk that found NO translation (so the requester can fault)
    reg         wres_valid, wres_i;
    reg  [19:0] wres_vpn;

    // TLB flush (sfence.vma in EX)
    wire        tlb_flush_all, tlb_flush_one;
    wire [31:0] tlb_flush_va;

    // =================================================================
    // IF
    // =================================================================
    reg  [31:0] pc;
    assign pc_out = pc;

    wire        itlb_hit; wire [31:0] itlb_pa; wire [3:0] itlb_perm;
    generate if (MMU) begin : g_itlb
        tlb #(.ENTRIES(TLB_ENTRIES)) u_itlb (
            .clk(clk), .rst(rst),
            .va(pc), .hit(itlb_hit), .pa(itlb_pa), .perm(itlb_perm),
            .fill(ptw_fill & ptw_side_i), .fill_va(ptw_va), .fill_ppn(ptw_ppn),
            .fill_super(ptw_super), .fill_perm(ptw_perm),
            .flush_all(tlb_flush_all), .flush_one(tlb_flush_one), .flush_va(tlb_flush_va)
        );
    end else begin : g_no_itlb
        assign itlb_hit = 1'b0; assign itlb_pa = pc; assign itlb_perm = 4'b0;
    end endgenerate
    wire if_wres_fault = wres_valid & wres_i & (wres_vpn == pc[31:12]);
    // fetch needs X, and U must match the mode: U runs only U pages, S never
    // executes a U page (SUM does not apply to fetch)
    wire fetch_ok = itlb_perm[2] & (in_user ? itlb_perm[3] : ~itlb_perm[3]);
    wire if_fault = vm_on & (itlb_hit ? ~fetch_ok : if_wres_fault);
    wire if_walk  = vm_on & ~itlb_hit & ~if_wres_fault;

    assign i_addr = vm_on ? itlb_pa : pc;
    assign i_req  = ~rst & ~halt & ~if_fault & ~if_walk;
    // an instruction -- or a fault token -- is ready to enter ID
    wire if_ok = if_fault | (i_req & i_ready);

    reg [31:0] ifid_pc, ifid_instr, ifid_pred_target;
    reg        ifid_valid, ifid_ifault, ifid_pred_taken;
    wire       front_hold = ex_hold | load_use;

    // ---- branch prediction (combinational on the IF PC) ----
    wire        bp_taken;
    wire [31:0] bp_target;
    wire        bp_upd_en, bp_upd_taken, bp_upd_jump;
    wire [31:0] bp_upd_pc, bp_upd_target;
    generate if (BPRED) begin : g_bp
        branch_predictor #(.IDX_BITS(BP_IDX_BITS)) u_bp (
            .clk(clk), .rst(rst),
            .pc_if(pc), .predict_taken(bp_taken), .predict_target(bp_target),
            .upd_en(bp_upd_en), .upd_pc(bp_upd_pc), .upd_taken(bp_upd_taken),
            .upd_is_jump(bp_upd_jump), .upd_target(bp_upd_target)
        );
    end else begin : g_nobp
        assign bp_taken = 1'b0; assign bp_target = 32'd0;
    end endgenerate
    wire [31:0] pc_next = bp_taken ? bp_target : pc + 32'd4;

    always @(posedge clk) begin
        if (rst) pc <= RESET_PC;
        else if (freeze)               pc <= pc;
        else if (flush)                pc <= redirect_pc;
        else if (front_hold | ~if_ok)  pc <= pc;
        else                           pc <= pc_next;
    end
    always @(posedge clk) begin
        if (rst || (flush && !freeze)) begin
            ifid_instr <= NOP; ifid_pc <= 32'd0; ifid_valid <= 1'b0; ifid_ifault <= 1'b0;
            ifid_pred_taken <= 1'b0; ifid_pred_target <= 32'd0;
        end else if (freeze || front_hold) begin
            // hold
        end else if (if_ok) begin
            ifid_instr  <= if_fault ? NOP : i_rdata;
            ifid_pc     <= pc;
            ifid_valid  <= 1'b1;
            ifid_ifault <= if_fault;
            ifid_pred_taken <= bp_taken; ifid_pred_target <= bp_target;
        end else begin                                    // I-port busy: bubble
            ifid_instr <= NOP; ifid_valid <= 1'b0; ifid_ifault <= 1'b0;
            ifid_pred_taken <= 1'b0;
        end
    end

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

    // SYSTEM / atomics decode
    wire is_system = (opcode == 7'b1110011);
    wire id_is_csr = is_system && (funct3_id != 3'b000);
    wire id_is_mret= is_system && (funct3_id==3'b000) && (ifid_instr[31:20]==12'h302);
    wire id_ecall  = is_system && (funct3_id==3'b000) && (ifid_instr[31:20]==12'h000);
    wire id_ebreak = is_system && (funct3_id==3'b000) && (ifid_instr[31:20]==12'h001);
    wire id_sret   = is_system && (funct3_id==3'b000) && (ifid_instr[31:20]==12'h102);
    wire id_sfence = is_system && (funct3_id==3'b000) && (funct7==7'b0001001);
    wire id_is_amo = (A_EXT != 0) && (opcode == 7'b0101111) && (funct3_id == 3'b010);   // .w only
    wire id_muldiv = (opcode == 7'b0110011) && (funct7 == 7'b0000001);
    wire [4:0] id_amo_f5 = funct7[6:2];
    wire id_lr  = id_is_amo & (id_amo_f5 == 5'b00010);
    wire id_sc  = id_is_amo & (id_amo_f5 == 5'b00011);
    wire id_rmw = id_is_amo & ~id_lr & ~id_sc;
    wire op_known =
        (opcode==7'b0110011)||(opcode==7'b0010011)||(opcode==7'b0000011)||
        (opcode==7'b0100011)||(opcode==7'b1100011)||(opcode==7'b1101111)||
        (opcode==7'b1100111)||(opcode==7'b0110111)||(opcode==7'b0010111)||
        (opcode==7'b1110011)||(opcode==7'b0001111)||id_is_amo;
    wire op_ok = op_known & ~(id_muldiv & (M_EXT == 0));     // RV32M absent

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
    reg [31:0] idex_pc, idex_imm, idex_rs1d, idex_rs2d, idex_instr, idex_pred_target;
    reg [4:0]  idex_rs1, idex_rs2, idex_rd, idex_alu_op, idex_amo_f5;
    reg [2:0]  idex_funct3;
    reg [1:0]  idex_wb_sel;
    reg [11:0] idex_csr_addr;
    reg        idex_reg_write, idex_alu_src_a, idex_alu_src_b,
               idex_mem_read, idex_mem_write, idex_branch, idex_jump, idex_jalr,
               idex_is_csr, idex_is_mret, idex_ecall, idex_ebreak, idex_illegal,
               idex_sfence, idex_lr, idex_sc, idex_rmw, idex_ifault, idex_valid,
               idex_sret, idex_pred_taken;
    wire [31:0] opA, opB;               // forwarded operands (EX)

    always @(posedge clk) begin
        if (rst || (!freeze && !ex_hold && (flush || load_use))) begin
            idex_reg_write<=0; idex_mem_read<=0; idex_mem_write<=0;
            idex_branch<=0; idex_jump<=0; idex_jalr<=0; idex_alu_src_a<=0;
            idex_alu_src_b<=0; idex_wb_sel<=WB_ALU; idex_alu_op<=0;
            idex_rd<=0; idex_rs1<=0; idex_rs2<=0; idex_funct3<=0;
            idex_pc<=0; idex_imm<=0; idex_rs1d<=0; idex_rs2d<=0;
            idex_is_csr<=0; idex_is_mret<=0; idex_ecall<=0; idex_ebreak<=0;
            idex_illegal<=0; idex_csr_addr<=0; idex_sfence<=0; idex_amo_f5<=0;
            idex_lr<=0; idex_sc<=0; idex_rmw<=0; idex_ifault<=0; idex_valid<=0;
            idex_sret<=0; idex_instr<=0; idex_pred_taken<=0; idex_pred_target<=0;
        end else if (freeze || ex_hold) begin
            // hold, but keep the operands current: a producer that leaves
            // WB while we wait must not take its forwarded value with it
            idex_rs1d <= opA; idex_rs2d <= opB;
        end else begin
            idex_reg_write<=c_reg_write | id_is_amo; idex_mem_read<=c_mem_read | id_is_amo;
            idex_mem_write<=c_mem_write; idex_branch<=c_branch;
            idex_jump<=c_jump; idex_jalr<=c_jalr; idex_alu_src_a<=c_alu_src_a;
            idex_alu_src_b<=c_alu_src_b; idex_wb_sel<=id_is_amo ? WB_MEM : c_wb_sel;
            idex_alu_op<=c_alu_op;
            idex_rd<=rd_id; idex_rs1<=rs1_id; idex_rs2<=rs2_id;
            idex_funct3<=id_is_amo ? 3'b010 : funct3_id;
            idex_pc<=ifid_pc; idex_imm<=imm_id; idex_rs1d<=rs1_data_id; idex_rs2d<=rs2_data_id;
            idex_is_csr<=id_is_csr; idex_is_mret<=id_is_mret; idex_ecall<=id_ecall;
            idex_ebreak<=id_ebreak; idex_illegal<=~op_ok;
            idex_csr_addr<=ifid_instr[31:20]; idex_sfence<=id_sfence;
            idex_amo_f5<=id_amo_f5; idex_lr<=id_lr; idex_sc<=id_sc; idex_rmw<=id_rmw;
            idex_ifault<=ifid_ifault; idex_valid<=ifid_valid;
            idex_sret<=id_sret; idex_instr<=ifid_instr;
            idex_pred_taken<=ifid_pred_taken; idex_pred_target<=ifid_pred_target;
        end
    end

    // =================================================================
    // EX  (+ CSR, data translation, trap commit)
    // =================================================================
    reg        exmem_reg_write; reg [4:0] exmem_rd; reg [31:0] exmem_result;

    // forwarding (plain continuous assigns -- see cpu_pipe_trap)
    wire fwdA_exmem = exmem_reg_write && exmem_rd!=0 && exmem_rd==idex_rs1;
    wire fwdA_memwb = wb_reg_write    && wb_rd!=0    && wb_rd==idex_rs1;
    wire fwdB_exmem = exmem_reg_write && exmem_rd!=0 && exmem_rd==idex_rs2;
    wire fwdB_memwb = wb_reg_write    && wb_rd!=0    && wb_rd==idex_rs2;
    assign opA = fwdA_exmem ? exmem_result : fwdA_memwb ? wb_data : idex_rs1d;
    assign opB = fwdB_exmem ? exmem_result : fwdB_memwb ? wb_data : idex_rs2d;

    wire [31:0] alu_a = idex_alu_src_a ? idex_pc  : opA;
    wire [31:0] alu_b = idex_alu_src_b ? idex_imm : opB;
    wire [31:0] alu_result; wire alu_zero;
    alu #(.M_EXT(M_EXT)) u_alu (.a(alu_a), .b(alu_b), .alu_op(idex_alu_op), .result(alu_result), .zero(alu_zero));

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
    wire        ex_taken  = idex_jump | (idex_branch & branch_cond);
    wire [31:0] ex_target = idex_jalr ? jalr_tgt : br_target;

    // ---- data address + translation ----
    wire        ex_amo   = idex_lr | idex_sc | idex_rmw;
    wire        ex_mem   = idex_valid & (idex_mem_read | idex_mem_write);
    wire [31:0] ex_va    = ex_amo ? opA : alu_result;       // atomics: (rs1), no offset
    wire        need_r   = (idex_mem_read & ~idex_sc) ;     // load, LR, AMO
    wire        need_w   = idex_mem_write | idex_sc | idex_rmw;

    wire        dtlb_hit; wire [31:0] dtlb_pa; wire [3:0] dtlb_perm;
    generate if (MMU) begin : g_dtlb
        tlb #(.ENTRIES(TLB_ENTRIES)) u_dtlb (
            .clk(clk), .rst(rst),
            .va(ex_va), .hit(dtlb_hit), .pa(dtlb_pa), .perm(dtlb_perm),
            .fill(ptw_fill & ~ptw_side_i), .fill_va(ptw_va), .fill_ppn(ptw_ppn),
            .fill_super(ptw_super), .fill_perm(ptw_perm),
            .flush_all(tlb_flush_all), .flush_one(tlb_flush_one), .flush_va(tlb_flush_va)
        );
    end else begin : g_no_dtlb
        assign dtlb_hit = 1'b0; assign dtlb_pa = ex_va; assign dtlb_perm = 4'b0;
    end endgenerate
    wire ex_xlate      = ex_mem & vm_on;
    wire ex_wres_fault = wres_valid & ~wres_i & (wres_vpn == ex_va[31:12]);
    // {U,X,W,R}: U-mode needs a U page; S may use a U page only with SUM;
    // MXR lets loads read execute-only pages
    wire user_ok       = in_user ? dtlb_perm[3] : (~dtlb_perm[3] | st_sum);
    wire readable      = dtlb_perm[0] | (st_mxr & dtlb_perm[2]);
    wire perm_ok       = user_ok & (~need_r | readable) & (~need_w | dtlb_perm[1]);
    wire ex_dfault     = ex_xlate & (dtlb_hit ? ~perm_ok : ex_wres_fault);
    wire ex_dwalk      = ex_xlate & ~dtlb_hit & ~ex_wres_fault;
    wire [31:0] ex_pa  = ex_xlate ? dtlb_pa : ex_va;

    // ---- privilege / exceptions ----
    // a CSR's address bits [9:8] are the lowest privilege that may touch it
    // ... and without S-mode the S-level CSRs do not exist (except satp,
    // which an MMU with only M/U still needs)
    wire csr_no_s   = (HAS_S == 0) & (idex_csr_addr[9:8] == 2'b01) &
                      ~((MMU != 0) & (idex_csr_addr == 12'h180));
    wire csr_bad    = idex_is_csr & ((idex_csr_addr[9:8] > cur_priv) | csr_no_s);
    wire ex_illegal = idex_illegal | csr_bad |
                      (idex_is_mret & ~in_m) |
                      (idex_sret & ((HAS_S == 0) | in_user)) |
                      (in_user & idex_sfence);
    wire [31:0] csr_rdata, trap_vector, mepc_out, sepc_out, irq_cause;
    wire        irq_pending;
    wire [31:0] csr_wsrc = idex_funct3[2] ? {27'b0, idex_rs1} : opA;

    assign ex_hold = ex_dwalk;                 // (implies idex_valid)
    assign ex_go   = idex_valid & ~freeze & ~ex_hold;

    wire exception = idex_ifault | ex_illegal | idex_ecall | idex_ebreak | ex_dfault;
    wire irq_take  = irq_pending & ~exception & ~idex_is_mret & ~idex_sret & ~idex_is_csr;
    assign take_trap = ex_go & (exception | irq_take);
    wire mret_ex   = ex_go & idex_is_mret & ~take_trap;
    wire sret_ex   = ex_go & idex_sret    & ~take_trap;
    wire csr_commit= ex_go & idex_is_csr  & ~take_trap;
    wire sfence_ex = ex_go & idex_sfence  & ~take_trap;

    wire [31:0] trap_cause = idex_ifault ? 32'd12 :
                             ex_illegal  ? 32'd2  :
                             idex_ecall  ? (in_user ? 32'd8 : in_m ? 32'd11 : 32'd9) :
                             idex_ebreak ? 32'd3  :
                             ex_dfault   ? (need_w ? 32'd15 : 32'd13) :
                                           irq_cause;
    // mtval / stval: the faulting VA, the bad instruction, or the PC
    wire [31:0] trap_val   = idex_ifault ? idex_pc    :
                             ex_illegal  ? idex_instr :
                             idex_ebreak ? idex_pc    :
                             ex_dfault   ? ex_va      : 32'd0;

    csr_s #(.HAS_S(HAS_S), .HAS_U(HAS_U), .HAS_SATP(MMU)) u_csr (
        .clk(clk), .rst(rst),
        .csr_addr(idex_csr_addr), .csr_funct3(idex_funct3), .csr_wsrc(csr_wsrc),
        .csr_we(csr_commit), .csr_rdata(csr_rdata),
        .pc(idex_pc), .timer_irq(timer_irq), .ext_irq(1'b0),
        .instr_is_mret(mret_ex), .instr_is_sret(sret_ex),
        .take_trap(take_trap), .trap_cause(trap_cause), .trap_val(trap_val),
        .trap_vector(trap_vector), .mret_target(mepc_out), .sret_target(sepc_out),
        .irq_pending(irq_pending), .irq_cause(irq_cause), .deleg_now(),
        .status_sum(st_sum), .status_mxr(st_mxr),
        .cur_priv(cur_priv), .satp_out(satp_val)
    );

    assign tlb_flush_all = sfence_ex & (idex_rs1 == 5'd0);
    assign tlb_flush_one = sfence_ex & (idex_rs1 != 5'd0);
    assign tlb_flush_va  = opA;

    // ---- check the IF-stage prediction against what EX resolved ----
    wire ex_ctrl   = idex_branch | idex_jump | idex_jalr;
    wire mispred   = ex_ctrl ? ((ex_taken != idex_pred_taken) |
                                (ex_taken & (ex_target != idex_pred_target)))
                             : idex_pred_taken;          // "taken" on a non-branch
    assign bp_upd_en     = ex_go & ex_ctrl & ~take_trap;
    assign bp_upd_pc     = idex_pc;
    assign bp_upd_taken  = ex_taken;
    assign bp_upd_jump   = idex_jump | idex_jalr;
    assign bp_upd_target = ex_target;

    assign redirect    = take_trap | mret_ex | sret_ex | (ex_go & mispred);
    assign redirect_pc = take_trap ? trap_vector :
                         mret_ex   ? mepc_out    :
                         sret_ex   ? sepc_out    :
                         ex_taken  ? ex_target   : pc4_ex;

    wire [31:0] ex_result = idex_is_csr           ? csr_rdata :
                            (idex_wb_sel==WB_PC4)  ? pc4_ex    :
                            (idex_wb_sel==WB_IMM)  ? idex_imm  : alu_result;
    wire ex_keep = ex_go & ~take_trap;        // instruction moves on to MEM

    // EX/MEM register
    reg [31:0] exmem_addr, exmem_store; reg [2:0] exmem_funct3;
    reg [4:0]  exmem_amo_f5;
    reg [1:0]  exmem_wb_sel;
    reg        exmem_mem_read, exmem_mem_write, exmem_lr, exmem_sc, exmem_rmw, exmem_valid;
    always @(posedge clk) begin
        if (rst || (!freeze && !ex_keep)) begin          // bubble (incl. ex_hold)
            exmem_reg_write<=0; exmem_mem_read<=0; exmem_mem_write<=0;
            exmem_lr<=0; exmem_sc<=0; exmem_rmw<=0; exmem_valid<=0;
            exmem_rd<=0; exmem_result<=0; exmem_addr<=0; exmem_store<=0;
            exmem_funct3<=0; exmem_wb_sel<=WB_ALU; exmem_amo_f5<=0;
        end else if (!freeze) begin
            exmem_reg_write<=idex_is_csr | idex_reg_write;
            exmem_mem_read<=idex_mem_read; exmem_mem_write<=idex_mem_write;
            exmem_lr<=idex_lr; exmem_sc<=idex_sc; exmem_rmw<=idex_rmw;
            exmem_valid<=1'b1; exmem_rd<=idex_rd;
            exmem_result<=ex_result; exmem_addr<=ex_pa; exmem_store<=opB;
            exmem_funct3<=idex_funct3; exmem_amo_f5<=idex_amo_f5;
            exmem_wb_sel<=idex_is_csr ? WB_ALU : idex_wb_sel;
        end
    end

    assign load_use = idex_valid && idex_mem_read && idex_rd!=0 &&
                      ((idex_rd==rs1_id) || (idex_rd==rs2_id));

    // =================================================================
    // MEM  (one D-port request; an AMO makes two)
    // =================================================================
    reg        resv_valid; reg [31:0] resv_addr;    // LR/SC reservation
    reg        amo_ph;                              // AMO: 0 = read, 1 = write
    reg [31:0] amo_old;

    wire sc_ok    = exmem_sc & resv_valid & (resv_addr == exmem_addr);
    wire m_load   = exmem_mem_read & ~exmem_sc & ~exmem_rmw;   // load, LR
    wire m_store  = exmem_mem_write | sc_ok;
    wire m_port   = m_load | m_store | exmem_rmw;              // needs the D-port
    wire m_write  = m_store | (exmem_rmw & amo_ph);
    wire m_last   = ~exmem_rmw | amo_ph;                       // final request

    wire [1:0] ba = exmem_addr[1:0];
    wire [31:0] st_data = (exmem_funct3[1:0]==2'b00) ? (exmem_store[7:0]  << (8*ba)) :
                          (exmem_funct3[1:0]==2'b01) ? (exmem_store[15:0] << (8*ba)) : exmem_store;
    wire [3:0]  st_mask = (exmem_funct3[1:0]==2'b00) ? (4'b0001 << ba) :
                          (exmem_funct3[1:0]==2'b01) ? (4'b0011 << ba) : 4'b1111;

    reg [31:0] amo_new;
    always @(*) case (exmem_amo_f5)
        5'b00001: amo_new = exmem_store;                                       // SWAP
        5'b00000: amo_new = amo_old + exmem_store;                             // ADD
        5'b00100: amo_new = amo_old ^ exmem_store;                             // XOR
        5'b01100: amo_new = amo_old & exmem_store;                             // AND
        5'b01000: amo_new = amo_old | exmem_store;                             // OR
        5'b10000: amo_new = ($signed(amo_old) < $signed(exmem_store)) ? amo_old : exmem_store; // MIN
        5'b10100: amo_new = ($signed(amo_old) > $signed(exmem_store)) ? amo_old : exmem_store; // MAX
        5'b11000: amo_new = (amo_old < exmem_store) ? amo_old : exmem_store;   // MINU
        5'b11100: amo_new = (amo_old > exmem_store) ? amo_old : exmem_store;   // MAXU
        default:  amo_new = exmem_store;
    endcase

    // ---- D-port: the walker owns it while busy, else MEM ----
    wire m_req   = m_port & ~ptw_busy & ~halt;
    wire m_done  = m_req & d_ready;
    assign freeze = halt | (m_port & ~(m_done & m_last));

    assign d_addr  = ptw_busy ? ptw_addr : exmem_addr;
    assign d_req   = ptw_busy | m_req;
    assign d_we    = ptw_busy ? 4'b0000 : (m_write ? (exmem_rmw ? 4'b1111 : st_mask) : 4'b0000);
    assign d_wdata = exmem_rmw ? amo_new : st_data;

    always @(posedge clk) begin
        if (rst) begin
            amo_ph <= 1'b0; amo_old <= 32'd0; resv_valid <= 1'b0; resv_addr <= 32'd0;
        end else begin
            if (exmem_rmw & m_done & ~amo_ph) begin amo_ph <= 1'b1; amo_old <= d_rdata; end
            if (exmem_rmw & m_done &  amo_ph) amo_ph <= 1'b0;
            // reservation: a younger trap (EX) wins over an older LR (MEM)
            if (take_trap)                            resv_valid <= 1'b0;
            else if (exmem_lr & m_done)               begin resv_valid <= 1'b1; resv_addr <= exmem_addr; end
            else if ((exmem_sc | exmem_rmw) & ~freeze) resv_valid <= 1'b0;
        end
    end

    // ---- load extraction ----
    wire [31:0] dw = d_rdata;
    reg  [31:0] load_val;
    always @(*) begin
        case (exmem_funct3)
            3'b000: case (ba)
                2'd0: load_val={{24{dw[7]}},dw[7:0]};   2'd1: load_val={{24{dw[15]}},dw[15:8]};
                2'd2: load_val={{24{dw[23]}},dw[23:16]}; default: load_val={{24{dw[31]}},dw[31:24]};
            endcase
            3'b001: load_val = ba[1] ? {{16{dw[31]}},dw[31:16]} : {{16{dw[15]}},dw[15:0]};
            3'b100: load_val = (ba==0)?{24'd0,dw[7:0]}:(ba==1)?{24'd0,dw[15:8]}:
                               (ba==2)?{24'd0,dw[23:16]}:{24'd0,dw[31:24]};
            3'b101: load_val = ba[1] ? {16'd0,dw[31:16]} : {16'd0,dw[15:0]};
            default: load_val = dw;
        endcase
    end
    wire [31:0] mem_value = exmem_sc  ? {31'd0, ~sc_ok} :     // SC: 0 = success
                            exmem_rmw ? amo_old : load_val;
    wire [31:0] memwb_value = (exmem_wb_sel==WB_MEM) ? mem_value : exmem_result;

    reg memwb_reg_write, memwb_valid; reg [4:0] memwb_rd; reg [31:0] memwb_data;
    always @(posedge clk) begin
        if (rst || freeze) begin memwb_reg_write<=0; memwb_valid<=0; memwb_rd<=0; memwb_data<=0; end
        else begin
            memwb_reg_write<=exmem_reg_write; memwb_valid<=exmem_valid;
            memwb_rd<=exmem_rd; memwb_data<=memwb_value;
        end
    end

    // =================================================================
    // WB
    // =================================================================
    assign wb_reg_write = memwb_reg_write;
    assign wb_rd        = memwb_rd;
    assign wb_data      = memwb_data;
    assign retire       = memwb_valid;

    // =================================================================
    // Page-table walker (shared; borrows the D-port)
    // =================================================================
    // A walk may only start when MEM is not using the port this cycle, so
    // it never cuts into a transfer; once started, MEM waits for it.
    wire ptw_start_d = ex_dwalk & ~m_port & ~halt;
    wire ptw_start_i = if_walk & ~m_port & ~flush & ~halt;
    generate if (MMU) begin : g_ptw
        ptw u_ptw (
            .clk(clk), .rst(rst), .satp(satp_val),
            .start_d(ptw_start_d), .va_d(ex_va),
            .start_i(ptw_start_i), .va_i(pc),
            .kill(flush),
            .busy(ptw_busy), .mem_addr(ptw_addr), .mem_rdata(d_rdata), .mem_ready(d_ready),
            .done_fill(ptw_fill), .done_fault(ptw_fault), .side_i(ptw_side_i), .va(ptw_va),
            .leaf_ppn(ptw_ppn), .leaf_super(ptw_super), .leaf_perm(ptw_perm)
        );
    end else begin : g_no_ptw
        assign ptw_busy = 1'b0; assign ptw_addr = 32'd0; assign ptw_fill = 1'b0;
        assign ptw_fault = 1'b0; assign ptw_side_i = 1'b0; assign ptw_va = 32'd0;
        assign ptw_ppn = 22'd0; assign ptw_super = 1'b0; assign ptw_perm = 4'd0;
    end endgenerate

    always @(posedge clk) begin
        if (rst || take_trap || sfence_ex) wres_valid <= 1'b0;
        else if (ptw_fault) begin
            wres_valid <= 1'b1; wres_i <= ptw_side_i; wres_vpn <= ptw_va[31:12];
        end else if (ptw_fill && ptw_va[31:12] == wres_vpn && ptw_side_i == wres_i)
            wres_valid <= 1'b0;
    end
endmodule

`default_nettype wire
