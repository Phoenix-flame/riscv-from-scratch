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
// predictor, ZBA/ZBB/ZBC/ZBS the bit-manipulation groups (Step 46),
// V_EXT the vector unit (Step 47, rtl/vec_unit.v), ZICNTR the cycle,
// instret and event counters (Step 48).
// tools/rvgen sets them from a Kconfig .config; all default on.
//
// Boot support (Step 49). `time` / `timeh` (0xC01 / 0xC81) read the
// platform's mtime, wired in from the CLINT, so S-mode code (and Linux)
// can read the time without a trap; SoCs without one tie it to 0.
// FENCE.I redirects to pc+4 from EX, so the instructions behind it are
// fetched again: on a SoC whose fetch and data share one memory (soc_boot)
// that is all it takes for freshly stored code to be executed. Behind
// caches (Step 51) it is not: `fencei_req` asks the SoC to write the D-cache
// back and invalidate the I-cache, and the fence waits in EX until
// `fencei_ack` (tie it to 1 where there is nothing to maintain).
//
// What a kernel expects of the hardware (Step 50). `meip` / `seip` are the
// machine and supervisor external-interrupt lines from a PLIC. PMA_* list
// the platform's physical regions and what each allows (read, write,
// execute); every access is checked against them BEFORE it is made, in the
// stage that can still trap precisely -- a fetch in IF (it rides down as a
// fault token, like a fetch page fault), a load / store / AMO in EX, a page-
// table read in the walker -- so a bus error is an instruction, load or
// store/AMO ACCESS fault (cause 1 / 5 / 7) with the address in mtval,
// never a load that quietly reads 0. PMA_N=0 allows everything (the old
// behaviour). SVADE=1: the walker faults on clear A / D bits (ptw.v).
//
// Misaligned addresses (Step 52). The D-port moves one aligned word, so a
// halfword at an odd address, or a word / LR / SC / AMO not on a 4-byte
// boundary, cannot be done in one access -- and until now it was done
// wrongly (the store mask and the load extract assume alignment). It now
// traps in EX: load address misaligned (cause 4, LR included) or store/AMO
// address misaligned (6), mtval = the virtual address. It is checked
// BEFORE translation (the spec allows either order), so a misaligned
// access never walks, faults on a page, or reaches the bus; software
// (an SBI, or the kernel the trap is delegated to) emulates it with byte
// accesses. Likewise a taken branch / jump whose target is not 4-byte
// aligned (there is no C extension) traps on the jump itself: instruction
// address misaligned (cause 0), mtval = the target, rd not written.
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
    parameter BPRED       = 1,        // 1 = BTB + 2-bit predictor, 0 = not-taken, 2 = the same in
                                      //   block RAM, read a cycle ahead (Step 60, bpred_b.v)
    parameter BP_IDX_BITS = 6,        // predictor tables: 2**BP_IDX_BITS entries (BPRED = 1)
    parameter BP_B_IDX    = 9,        // BPRED = 2: 2**BP_B_IDX entries
    parameter M_EXT       = 1,        // RV32M multiply/divide
    parameter DIV_ITER    = 0,        // 1: divide/remainder in a 32-cycle unit (div_iter.v) instead of
                                      //    array dividers in the ALU -- small, and EX holds meanwhile (Step 57)
    parameter MUL_2C      = 0,        // 1: multiplies in mul_2c, registered both sides: EX holds 2 cycles
    parameter AGU         = 0,        // 1: load/store addresses from their own adder (rs1 + imm), not the
                                      //    ALU result -- the multiplier and result mux leave the D-TLB's path
    parameter XLATE_2C    = 0,        // 1: a load/store spends 2 cycles in EX: D-TLB lookup, registered,
                                      //    then faults / region check / commit (Step 58; needs V_EXT = 0)
    parameter VALID_FLUSH = 0,        // 1: a flush clears only IF/ID's and ID/EX's valid bits, not every
                                      //    field -- EX acts only on a valid instruction (Step 58; V_EXT = 0)
    parameter REG_REDIRECT = 0,       // 1: a mispredicted branch/jump redirects the PC a cycle later, from
                                      //    a register; the wrong-path instruction then in EX is killed.
                                      //    One more cycle per taken branch (Step 58)
    parameter FWD_PRE     = 0,        // 1: forwarding's register-number compares made a cycle early, from
                                      //    the next cycle's rd/rs; EX only ANDs them with reg_write (Step 58)
    parameter IF_PAGE     = 0,        // 1: fetch translates through a registered copy of the current page's
                                      //    translation; a new page costs one cycle to look up (Step 58)
    parameter D_PAGE      = 0,        // 1 (with XLATE_2C): a load/store in the page of the last one skips
                                      //   the lookup cycle, translated by a registered copy (Step 61)
    parameter HPM_LATE    = 0,        // 1: hpmcounter3..7 count their event a cycle late, from a register
                                      //    (mcycle / minstret stay exact) (Step 58)
    parameter A_EXT       = 1,        // RV32A atomics
    parameter HAS_U       = 1,        // user mode
    parameter HAS_S       = 1,        // supervisor mode + delegation (needs HAS_U)
    parameter MMU         = 1,        // Sv32 + TLBs + walker (needs HAS_U)
    parameter ZBA         = 1,        // bit-manip: address generation   (Step 46)
    parameter ZBB         = 1,        //            basic bit manipulation
    parameter ZBC         = 1,        //            carry-less multiply
    parameter ZBS         = 1,        //            single-bit operations
    parameter V_EXT       = 1,        // vectors: Zve32x subset (Step 47)
    parameter VLEN        = 128,      //          vector register width in bits
    parameter ZICNTR      = 1,        // cycle/instret/event counters     (Step 48)
    parameter SVADE       = 0,        // fault on clear PTE A/D bits      (Step 50)
    parameter PMA_N       = 0,        // physical regions (max 8); 0 = all RWX
    parameter [8*32-1:0] PMA_BASE = 0,    // region r: [base, base+size) ...
    parameter [8*32-1:0] PMA_SIZE = 0,
    parameter [8*3-1:0]  PMA_ATTR = 0     // ... allowing {X, W, R}
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        timer_irq,
    input  wire [63:0] mtime,         // platform timer, read as the time CSR
    input  wire        meip,          // external interrupts (PLIC contexts)
    input  wire        seip,
    input  wire        halt,          // freeze (SoC halt register)
    output wire        fencei_req,    // a FENCE.I in EX wants the caches made coherent
    input  wire        fencei_ack,    // ... done (1 = nothing to do)

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

    // ---- hints for caches that read a cycle ahead (Step 59): the address
    //      each port will likely present next cycle; only ever a guess ----
    output wire [31:0] i_addr_next,
    output wire [31:0] d_addr_next,
    output wire        d_hint_ok,     // ... and d_addr_next is a promise: the next D request, if any, is there

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
    reg         rr_valid;             // REG_REDIRECT: a branch in MEM redirects to rr_pc
    reg  [31:0] rr_pc;
    wire        flush = redirect | rr_valid;
    wire [31:0] flush_pc = rr_valid ? rr_pc : redirect_pc;

    wire [1:0]  cur_priv;
    wire [31:0] satp_val;
    wire        st_sum, st_mxr;            // mstatus.SUM / MXR
    wire [1:0]  st_vs;                     // mstatus.VS
    wire        v_vs_dirty;
    wire        in_user = (cur_priv == 2'b00);
    wire        in_m    = (cur_priv == 2'b11);
    wire        vm_on   = (MMU != 0) & ~in_m & satp_val[31];   // S and U are translated

    // ---- walker <-> TLB plumbing (driven further down) ----
    wire        ptw_busy, ptw_req, ptw_fill, ptw_fault, ptw_af, ptw_side_i, ptw_super;
    wire [31:0] ptw_va, ptw_addr;
    wire [21:0] ptw_ppn;
    wire [3:0]  ptw_perm;
    // last walk that found NO translation (so the requester can fault)
    reg         wres_valid, wres_i;
    reg  [19:0] wres_vpn;

    // ---- physical memory attributes: what may be done at a physical address ----
    // in_region(a, r) is a - base < size, written so it needs no carry
    // chain where it can (Step 58): a power-of-two region on its own
    // alignment is a compare of the bits above it; any other is two
    // compares in parallel (base <= a, a < base + size), on the bits above
    // the alignment base and size share. base + size may be 2^32 (hi = 0).
    // x < c without the `<` operator, so a constant c reduces to a few LUTs
    // instead of a carry chain (Step 59)
    function lt_bits;
        input [31:0] x, c;
        integer i;
        reg lt, eq;
        begin
            lt = 1'b0; eq = 1'b1;
            for (i = 31; i >= 0; i = i - 1) begin
                lt = lt | (eq & ~x[i] & c[i]);
                eq = eq & (x[i] == c[i]);
            end
            lt_bits = lt;
        end
    endfunction
    function in_region;
        input [31:0] a;
        input [31:0] b, sz;
        reg   [31:0] hi, m;
        integer g, k;
        begin
            hi = b + sz;
            if (sz != 0 && (sz & (sz - 1)) == 0 && (b & (sz - 1)) == 0) begin
                m = ~(sz - 1);
                in_region = ((a ^ b) & m) == 32'd0;
            end else begin
                g = 0;                            // shared alignment: 2^g
                for (k = 1; k < 32; k = k + 1)
                    if (((b | sz) & ((32'd1 << k) - 1)) == 0) g = k;
                in_region = (sz != 0) && !lt_bits(a >> g, b >> g) &&
                            ((hi == 0) || lt_bits(a >> g, hi >> g));
            end
        end
    endfunction
    function [2:0] pma;                       // {X, W, R}
        input [31:0] a;
        integer r;
        begin
            pma = (PMA_N == 0) ? 3'b111 : 3'b000;
            for (r = 0; r < PMA_N; r = r + 1)
                if (in_region(a, PMA_BASE[32*r +: 32], PMA_SIZE[32*r +: 32])) pma = PMA_ATTR[3*r +: 3];
        end
    endfunction
    reg wres_af;                              // ... that walk could not read a PTE

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
        tlb #(.ENTRIES(TLB_ENTRIES), .FAST_FILL(XLATE_2C)) u_itlb (
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
    wire if_pfault_l = vm_on & (itlb_hit ? ~fetch_ok : if_wres_fault);
    wire if_walk_l   = vm_on & ~itlb_hit & ~if_wres_fault;
    wire [31:0] i_addr_l = vm_on ? itlb_pa : pc;

    // IF_PAGE (Step 58): the lookup above, registered for the page the PC is
    // in (ip_*), so a fetch in that page sees no TLB on its path. Leaving the
    // page costs a cycle: no fetch, the lookup is registered, then the fetch.
    // Anything that can change a lookup's answer drops the copy (the
    // always block further down): a CSR write, a trap, mret / sret,
    // sfence.vma, and the end of any walk (a TLB fill, or a fault that sets
    // wres_*). The region check stays live, on the registered address.
    reg         ip_valid, ip_pf, ip_waf;
    reg  [19:0] ip_vpn, ip_ppn;
    wire        ip_hit = ip_valid & (pc[31:12] == ip_vpn);
    wire        if_pfault = IF_PAGE ? ip_hit & ip_pf : if_pfault_l;
    wire        if_walk   = IF_PAGE ? ~ip_hit & if_walk_l : if_walk_l;

    assign i_addr = IF_PAGE ? {ip_ppn, pc[11:0]} : i_addr_l;
    // a fetch outside executable memory is an access fault -- and so is a
    // fetch whose walk could not read its page table
    wire [2:0] if_pma = pma(i_addr);
    wire if_afault = IF_PAGE ? ip_hit & ((~ip_pf & ~if_pma[2]) | (ip_pf & ip_waf)) :
                     (~if_pfault & ~if_walk & ~if_pma[2]) | (if_pfault & ~itlb_hit & wres_af);
    wire if_fault  = if_pfault | if_afault;
    assign i_req  = ~rst & ~halt & ~if_fault & ~if_walk & ((IF_PAGE == 0) | ip_hit);
    // an instruction -- or a fault token -- is ready to enter ID
    wire if_ok = if_fault | (i_req & i_ready);

    reg [31:0] ifid_pc, ifid_instr, ifid_pred_target;
    reg        ifid_valid, ifid_ifault, ifid_iaf, ifid_pred_taken;
    reg [2:0]  ifid_bp_info;
    wire       front_hold = ex_hold | load_use;

    // ---- branch prediction (combinational on the IF PC; BPRED = 2: read
    //      at the edge before, at the PC's next value) ----
    wire        bp_taken;
    wire [31:0] bp_target;
    wire [2:0]  bp_info;
    wire        bp_upd_en, bp_upd_taken, bp_upd_jump;
    wire [31:0] bp_upd_pc, bp_upd_target;
    wire [2:0]  bp_upd_info;
    wire [31:0] pc_d;
    generate if (BPRED == 2) begin : g_bpb
        bpred_b #(.IDX_BITS(BP_B_IDX)) u_bp (
            .clk(clk), .rst(rst),
            .rd_pc(pc_d), .pc(pc), .taken(bp_taken), .target(bp_target), .info(bp_info),
            .upd_en(bp_upd_en), .upd_pc(bp_upd_pc), .upd_taken(bp_upd_taken),
            .upd_is_jump(bp_upd_jump), .upd_target(bp_upd_target), .upd_info(bp_upd_info)
        );
    end else if (BPRED) begin : g_bp
        assign bp_info = 3'd0;
        branch_predictor #(.IDX_BITS(BP_IDX_BITS)) u_bp (
            .clk(clk), .rst(rst),
            .pc_if(pc), .predict_taken(bp_taken), .predict_target(bp_target),
            .upd_en(bp_upd_en), .upd_pc(bp_upd_pc), .upd_taken(bp_upd_taken),
            .upd_is_jump(bp_upd_jump), .upd_target(bp_upd_target)
        );
    end else begin : g_nobp
        assign bp_taken = 1'b0; assign bp_target = 32'd0; assign bp_info = 3'd0;
    end endgenerate
    wire [31:0] pc_next = bp_taken ? bp_target : pc + 32'd4;

    assign      pc_d = freeze              ? pc       :
                       flush               ? flush_pc :
                       (front_hold | ~if_ok) ? pc     : pc_next;
    always @(posedge clk)
        if (rst) pc <= RESET_PC;
        else     pc <= pc_d;
    // the next fetch's address: the next PC through this page's translation
    // (a new page, or translation without IF_PAGE, guesses wrong -- a cycle)
    assign i_addr_next = IF_PAGE ? {ip_ppn, pc_d[11:0]} : pc_d;
    always @(posedge clk) begin
        if (rst || (VALID_FLUSH == 0 && flush && !freeze)) begin
            ifid_instr <= NOP; ifid_pc <= 32'd0; ifid_valid <= 1'b0; ifid_ifault <= 1'b0;
            ifid_iaf <= 1'b0; ifid_pred_taken <= 1'b0; ifid_pred_target <= 32'd0; ifid_bp_info <= 3'd0;
        end else begin
            // (with VALID_FLUSH = 0 a flush took the branch above, so here it
            //  only ever comes with freeze; with 1 the fields below don't
            //  look at it -- only valid does -- so it stays off their enables)
            if (freeze || front_hold) begin
                // hold
            end else if (if_ok) begin
                ifid_instr  <= if_fault ? NOP : i_rdata;
                ifid_pc     <= pc;
                ifid_valid  <= 1'b1;
                ifid_ifault <= if_fault; ifid_iaf <= if_afault;
                ifid_pred_taken <= bp_taken; ifid_pred_target <= bp_target; ifid_bp_info <= bp_info;
            end else begin                                // I-port busy: bubble
                ifid_instr <= NOP; ifid_valid <= 1'b0; ifid_ifault <= 1'b0; ifid_iaf <= 1'b0;
                ifid_pred_taken <= 1'b0;
            end
            if (VALID_FLUSH != 0 && flush && !freeze)
                ifid_valid <= 1'b0;             // the rest is a dead instruction's
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
    wire id_fencei = (opcode == 7'b0001111) && (funct3_id == 3'b001);
    // vector encodings (Step 47): OP-V, and LOAD-FP / STORE-FP with a vector width
    wire id_vec = (V_EXT != 0) &&
                  ((opcode == 7'b1010111) ||
                   ((opcode == 7'b0000111 || opcode == 7'b0100111) && (funct3_id == 3'b000 || funct3_id[2])));
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
        (opcode==7'b1110011)||(opcode==7'b0001111)||id_is_amo||id_vec;
    // Strict decode of OP / OP-IMM (Step 46): besides the base and M
    // encodings, a funct7 is only legal if it is a configured Zb
    // instruction -- an unconfigured extension traps instead of quietly
    // executing as some base op.
    wire id_zb;
    zb_unit #(.ZBA(ZBA), .ZBB(ZBB), .ZBC(ZBC), .ZBS(ZBS)) u_zb_dec (
        .opcode(opcode), .funct3(funct3_id), .funct7(funct7), .rs2f(rs2_id),
        .a(32'd0), .b(32'd0), .hit(id_zb), .result());
    wire base_r = (funct7 == 7'b0000000) |
                  (funct7 == 7'b0100000 && (funct3_id == 3'b000 || funct3_id == 3'b101)) |
                  (funct7 == 7'b0000001 && M_EXT != 0);
    wire base_i = (funct3_id == 3'b001) ? (funct7 == 7'b0000000) :           // slli
                  (funct3_id == 3'b101) ? (funct7 == 7'b0000000 || funct7 == 7'b0100000) : 1'b1;
    wire enc_ok = (opcode == 7'b0110011) ? (base_r | id_zb) :
                  (opcode == 7'b0010011) ? (base_i | id_zb) : 1'b1;
    wire op_ok = op_known & enc_ok;

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
    reg [6:0]  idex_opcode, idex_funct7;
    reg        idex_zb, idex_vec;
    reg [1:0]  idex_wb_sel;
    reg [11:0] idex_csr_addr;
    reg        idex_reg_write, idex_alu_src_a, idex_alu_src_b,
               idex_mem_read, idex_mem_write, idex_branch, idex_jump, idex_jalr,
               idex_is_csr, idex_is_mret, idex_ecall, idex_ebreak, idex_illegal,
               idex_sfence, idex_lr, idex_sc, idex_rmw, idex_ifault, idex_valid_q,
               idex_sret, idex_pred_taken, idex_fencei, idex_iaf;
    reg [2:0]  idex_bp_info;
    reg        idex_tgt_ok;            // BPRED = 2: pc + imm is the predicted target (branch, jal)
    reg [31:0] idex_jx;                //            the base a jalr needs to land on it
    // the wrong-path instruction in EX behind a registered redirect is dead
    wire idex_valid = idex_valid_q & ~rr_valid;
    wire [31:0] opA, opB;               // forwarded operands (EX)

    wire idex_kill = !freeze && !ex_hold && (flush || load_use);   // a bubble into EX
    always @(posedge clk) begin
        if (rst || (VALID_FLUSH == 0 && idex_kill)) begin
            idex_reg_write<=0; idex_mem_read<=0; idex_mem_write<=0;
            idex_branch<=0; idex_jump<=0; idex_jalr<=0; idex_alu_src_a<=0;
            idex_alu_src_b<=0; idex_wb_sel<=WB_ALU; idex_alu_op<=0;
            idex_rd<=0; idex_rs1<=0; idex_rs2<=0; idex_funct3<=0;
            idex_pc<=0; idex_imm<=0; idex_rs1d<=0; idex_rs2d<=0;
            idex_is_csr<=0; idex_is_mret<=0; idex_ecall<=0; idex_ebreak<=0;
            idex_illegal<=0; idex_csr_addr<=0; idex_sfence<=0; idex_amo_f5<=0;
            idex_lr<=0; idex_sc<=0; idex_rmw<=0; idex_ifault<=0; idex_valid_q<=0;
            idex_opcode<=0; idex_funct7<=0; idex_zb<=0; idex_vec<=0;
            idex_sret<=0; idex_instr<=0; idex_pred_taken<=0; idex_pred_target<=0; idex_bp_info<=0;
            idex_fencei<=0; idex_iaf<=0;
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
            idex_ifault<=ifid_ifault; idex_iaf<=ifid_iaf; idex_valid_q<=ifid_valid & ~((VALID_FLUSH != 0) & idex_kill);
            idex_sret<=id_sret; idex_instr<=ifid_instr; idex_fencei<=id_fencei;
            idex_opcode<=opcode; idex_funct7<=funct7; idex_zb<=id_zb; idex_vec<=id_vec;
            idex_pred_taken<=ifid_pred_taken; idex_pred_target<=ifid_pred_target; idex_bp_info<=ifid_bp_info;
            idex_tgt_ok<=(ifid_pc + imm_id) == ifid_pred_target; idex_jx<=ifid_pred_target - imm_id;
        end
    end

    // =================================================================
    // EX  (+ CSR, data translation, trap commit)
    // =================================================================
    reg        exmem_reg_write; reg [4:0] exmem_rd; reg [31:0] exmem_result;

    // forwarding (plain continuous assigns -- see cpu_pipe_trap)
    wire mA_exmem = exmem_rd!=0 && exmem_rd==idex_rs1;
    wire mA_memwb = wb_rd!=0    && wb_rd==idex_rs1;
    wire mB_exmem = exmem_rd!=0 && exmem_rd==idex_rs2;
    wire mB_memwb = wb_rd!=0    && wb_rd==idex_rs2;
    // FWD_PRE: the same four compares, registered from the values these
    // registers take next cycle. EX/MEM's and MEM/WB's rd are only wrong in
    // there when that stage holds a bubble, whose reg_write is 0 anyway, so
    // only ID/EX's rs needs its exact next value.
    reg pA_exmem, pA_memwb, pB_exmem, pB_memwb;
    wire [4:0] nx_rs1 = ((VALID_FLUSH == 0) && idex_kill) ? 5'd0 : (freeze || ex_hold) ? idex_rs1 : rs1_id;
    wire [4:0] nx_rs2 = ((VALID_FLUSH == 0) && idex_kill) ? 5'd0 : (freeze || ex_hold) ? idex_rs2 : rs2_id;
    wire [4:0] nx_exmem_rd = freeze ? exmem_rd : idex_rd;      // (memwb_rd's next is exmem_rd)
    always @(posedge clk) begin
        pA_exmem <= nx_exmem_rd != 0 && nx_exmem_rd == nx_rs1;
        pB_exmem <= nx_exmem_rd != 0 && nx_exmem_rd == nx_rs2;
        pA_memwb <= exmem_rd != 0 && exmem_rd == nx_rs1;
        pB_memwb <= exmem_rd != 0 && exmem_rd == nx_rs2;
    end
    wire fwdA_exmem = exmem_reg_write && (FWD_PRE ? pA_exmem : mA_exmem);
    wire fwdA_memwb = wb_reg_write    && (FWD_PRE ? pA_memwb : mA_memwb);
    wire fwdB_exmem = exmem_reg_write && (FWD_PRE ? pB_exmem : mB_exmem);
    wire fwdB_memwb = wb_reg_write    && (FWD_PRE ? pB_memwb : mB_memwb);
`ifndef SYNTHESIS
    // simulation only: the registered compares must agree wherever they count
    always @(posedge clk)
        if (FWD_PRE != 0 && !rst &&
            ((exmem_reg_write && pA_exmem != mA_exmem) || (exmem_reg_write && pB_exmem != mB_exmem) ||
             (wb_reg_write && pA_memwb != mA_memwb)    || (wb_reg_write && pB_memwb != mB_memwb))) begin
            $display("FWD_PRE: forwarding compare mismatch at pc %h", idex_pc);
            $finish;
        end
`endif
    assign opA = fwdA_exmem ? exmem_result : fwdA_memwb ? wb_data : idex_rs1d;
    assign opB = fwdB_exmem ? exmem_result : fwdB_memwb ? wb_data : idex_rs2d;

    wire [31:0] alu_a = idex_alu_src_a ? idex_pc  : opA;
    wire [31:0] alu_b = idex_alu_src_b ? idex_imm : opB;
    wire [31:0] alu_result_i; wire alu_zero;
    alu #(.M_EXT(M_EXT), .DIV_ITER(DIV_ITER), .MUL_2C(MUL_2C)) u_alu (.a(alu_a), .b(alu_b),
        .alu_op(idex_alu_op), .result(alu_result_i), .zero(alu_zero));
    // DIV_ITER / MUL_2C: divides and multiplies come from their own units,
    // which hold EX until they have the result (div_wait, mul_wait, in
    // ex_hold below)
    wire        div_wait, mul_wait, is_div_ex, is_mul_ex;
    wire [31:0] div_res, mul_res;
    generate if (M_EXT && DIV_ITER) begin : g_div
        wire div_done;
        assign is_div_ex = idex_valid & (idex_alu_op >= 5'd14) & (idex_alu_op <= 5'd17);
        div_iter u_div (.clk(clk), .rst(rst), .want(is_div_ex), .start_ok(~freeze), .go(ex_go),
                        .op(idex_alu_op[1:0] + 2'd2), .a(alu_a), .b(alu_b),
                        .done(div_done), .result(div_res));
        assign div_wait = is_div_ex & ~div_done;
    end else begin : g_nodiv
        assign is_div_ex = 1'b0; assign div_wait = 1'b0; assign div_res = 32'd0;
    end endgenerate
    generate if (M_EXT && MUL_2C) begin : g_mul
        wire mul_done;
        assign is_mul_ex = idex_valid & (idex_alu_op >= 5'd10) & (idex_alu_op <= 5'd13);
        mul_2c u_mul (.clk(clk), .rst(rst), .want(is_mul_ex), .start_ok(~freeze), .go(ex_go),
                      .op(idex_alu_op[1:0] + 2'd2), .a(alu_a), .b(alu_b),
                      .done(mul_done), .result(mul_res));
        assign mul_wait = is_mul_ex & ~mul_done;
    end else begin : g_nomul
        assign is_mul_ex = 1'b0; assign mul_wait = 1'b0; assign mul_res = 32'd0;
    end endgenerate
    wire [31:0] alu_result = is_div_ex ? div_res : is_mul_ex ? mul_res : alu_result_i;

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
    // a load's or store's address is rs1 + imm, which is what the ALU adds
    // for them (ALU_ADD, alu_src_b); AGU gives it its own adder, so nothing
    // else the ALU result mux carries is on the path into the D-TLB
    wire [31:0] agu_va   = opA + idex_imm;
    wire [31:0] ex_va_live = ex_amo ? opA : (AGU ? agu_va : alu_result);  // atomics: (rs1), no offset
    // XLATE_2C (Step 58): the lookup and the decisions it feeds -- the faults,
    // the region check, a walk, the commit -- in different cycles. Cycle A
    // holds EX and registers the D-TLB's answer for this address (xl_*);
    // cycle B decides from the registers. Without it, both in one cycle.
    // A D-TLB fill or flush throws the registered lookup away, so after a
    // walk the lookup is simply done again, and hits.
    reg         xl_have, xl_hit;
    reg  [31:0] xl_va, xl_pa, xl_epa;   // the TLB's PA; the PA the access uses
    reg  [3:0]  xl_perm;
    reg  [2:0]  xl_pma;                 // pma() of xl_epa
    reg         pg_q;                   // D_PAGE: this one was translated in ID (pg_*)
    reg  [31:0] pg_va;
    reg  [19:0] pg_ppn;
    reg  [3:0]  pg_perm;
    reg  [2:0]  pg_pma;
    wire        pg_on    = (D_PAGE != 0) & (XLATE_2C != 0) & pg_q;
    wire        xl_wait  = (XLATE_2C != 0) & ex_mem & ~xl_have & ~pg_on;      // in ex_hold below
    wire        ex_mem_d = ex_mem & ((XLATE_2C == 0) | xl_have | pg_on);      // decisions may be made
    wire [31:0] ex_va    = XLATE_2C ? (pg_on ? pg_va : xl_va) : ex_va_live;
    wire        need_r   = (idex_mem_read & ~idex_sc) ;     // load, LR, AMO
    wire        need_w   = idex_mem_write | idex_sc | idex_rmw;
    // misaligned (Step 52): halfword on an odd address, word / atomic off
    // a 4-byte boundary; decided before translation, so it never walks
    wire        ex_misal = ex_mem_d & ((idex_funct3[1:0] == 2'b01) ? ex_va[0] :
                                       (idex_funct3[1:0] == 2'b10) ? (ex_va[1:0] != 2'b00) : 1'b0);
    wire        ex_imisal_full = idex_valid & ex_taken & ex_target[1];   // no C: IALIGN = 32
    // REG_REDIRECT: the misaligned-target exception without the branch
    // compare or the 32-bit add on its path. Bit 1 of a target is a 2-bit
    // add (jalr: rs1 + imm, in the ALU; the others pc + imm). A jump always
    // goes; a branch only if taken -- and a branch can be misaligned only
    // through its immediate, which compiled code never does without C, so
    // such a branch spends one cycle more in EX (bq_*) and traps on the
    // registered outcome.
    wire [1:0]  tgt_lo  = idex_jalr ? opA[1:0] : idex_pc[1:0];
    wire        tgt1    = tgt_lo[1] ^ idex_imm[1] ^ (tgt_lo[0] & idex_imm[0]);
    reg         bq_have, bq_taken;
    wire        bq_wait = (REG_REDIRECT != 0) & idex_valid & idex_branch & ~idex_jump & tgt1 & ~bq_have;
    wire        ex_imisal = (REG_REDIRECT == 0) ? ex_imisal_full :
                            idex_valid & tgt1 & (idex_jump | (idex_branch & bq_have & bq_taken));
`ifndef SYNTHESIS
    always @(posedge clk)
        if (REG_REDIRECT != 0 && !rst && ex_go && ex_imisal != ex_imisal_full) begin
            $display("REG_REDIRECT: misaligned-target mismatch at pc %h", idex_pc);
            $finish;
        end
`endif

    wire        dtlb_hit; wire [31:0] dtlb_pa; wire [3:0] dtlb_perm;
    generate if (MMU) begin : g_dtlb
        tlb #(.ENTRIES(TLB_ENTRIES), .FAST_FILL(XLATE_2C)) u_dtlb (
            .clk(clk), .rst(rst),
            .va(dtlb_va), .hit(dtlb_hit), .pa(dtlb_pa), .perm(dtlb_perm),
            .fill(ptw_fill & ~ptw_side_i), .fill_va(ptw_va), .fill_ppn(ptw_ppn),
            .fill_super(ptw_super), .fill_perm(ptw_perm),
            .flush_all(tlb_flush_all), .flush_one(tlb_flush_one), .flush_va(tlb_flush_va)
        );
    end else begin : g_no_dtlb
        assign dtlb_hit = 1'b0; assign dtlb_pa = dtlb_va; assign dtlb_perm = 4'b0;
    end endgenerate
    // what the decisions below see: the lookup now, or the registered one
    wire        d_hit  = XLATE_2C ? (pg_on | xl_hit) : dtlb_hit;
    wire [31:0] d_pa   = XLATE_2C ? xl_pa   : dtlb_pa;
    wire [3:0]  d_perm = XLATE_2C ? (pg_on ? pg_perm : xl_perm) : dtlb_perm;
    always @(posedge clk)
        if (rst || ex_go || !idex_valid || ptw_fill || tlb_flush_all || tlb_flush_one)
            xl_have <= 1'b0;
        else if (XLATE_2C && ex_mem && !xl_have && !pg_on && !freeze)
            xl_have <= 1'b1;
    // the lookup itself is taken every cycle until xl_have holds it, so its
    // enable never waits for freeze (the value xl_have keeps is the same)
    always @(posedge clk)
        if (XLATE_2C && !xl_have) begin
            xl_va   <= ex_va_live;
            xl_hit  <= dtlb_hit;  xl_pa <= dtlb_pa;  xl_perm <= dtlb_perm;
            xl_epa  <= xl_epa_a;  xl_pma <= pma(xl_epa_a);
        end
    always @(posedge clk)
        if (rst || ex_go || !idex_valid) bq_have <= 1'b0;
        else if (bq_wait && !freeze) begin bq_have <= 1'b1; bq_taken <= branch_cond; end
    wire ex_xlate      = ex_mem_d & vm_on & ~ex_misal;
    // cycle A's view of ex_pa below: the same choice, on the live lookup
    wire        misal_a  = (idex_funct3[1:0] == 2'b01) ? ex_va_live[0] :
                           (idex_funct3[1:0] == 2'b10) ? (ex_va_live[1:0] != 2'b00) : 1'b0;
    wire [31:0] xl_epa_a = (vm_on & ~misal_a) ? dtlb_pa : ex_va_live;
    wire ex_wres_fault = wres_valid & ~wres_i & (wres_vpn == ex_va[31:12]);
    // ---- vector element translation (the D-TLB is the vector unit's while it
    //      runs a memory instruction: the scalar pipe is held, MEM is empty) ----
    wire v_mem_active, v_mem_store, v_mem_want;
    wire [31:0] v_mem_va;
    wire [31:0] dtlb_va = v_mem_active ? v_mem_va : (XLATE_2C && xl_have) ? xl_va : ex_va_live;
    wire v_wres_fault  = wres_valid & ~wres_i & (wres_vpn == v_mem_va[31:12]);
    // {U,X,W,R}: U-mode needs a U page; S may use a U page only with SUM;
    // MXR lets loads read execute-only pages
    wire user_ok       = in_user ? d_perm[3] : (~d_perm[3] | st_sum);
    wire readable      = d_perm[0] | (st_mxr & d_perm[2]);
    wire perm_ok       = user_ok & (~need_r | readable) & (~need_w | d_perm[1]);
    wire ex_dfault     = ex_xlate & (d_hit ? ~perm_ok : ex_wres_fault);
    wire ex_dwalk      = ex_xlate & ~d_hit & ~ex_wres_fault;
    wire [31:0] ex_pa  = XLATE_2C ? (pg_on ? {pg_ppn, pg_va[11:0]} : xl_epa) : ex_xlate ? d_pa : ex_va;
    // access faults: the walk could not read a PTE, or the physical address
    // does not allow the access (loads need R; stores, SC and AMOs need W)
    wire [2:0]  ex_pma = XLATE_2C ? (pg_on ? pg_pma : xl_pma) : pma(ex_pa);
    wire ex_daf_walk   = ex_dfault & ~d_hit & wres_af;
    wire ex_daf_pma    = ex_mem_d & ~ex_misal & ~ex_dfault & ~ex_dwalk &
                         ((need_r & ~ex_pma[0]) | (need_w & ~ex_pma[1]));
    wire ex_daf        = ex_daf_walk | ex_daf_pma;
    wire v_user_ok     = in_user ? dtlb_perm[3] : (~dtlb_perm[3] | st_sum);
    wire v_readable    = dtlb_perm[0] | (st_mxr & dtlb_perm[2]);
    wire v_perm_ok     = v_user_ok & (v_mem_store ? dtlb_perm[1] : v_readable);
    wire v_xl_fault    = vm_on & (dtlb_hit ? ~v_perm_ok : v_wres_fault);
    wire v_xl_ok       = ~vm_on | (dtlb_hit & v_perm_ok);
    wire v_walk        = v_mem_active & v_mem_want & vm_on & ~dtlb_hit & ~v_wres_fault;
    wire [31:0] v_pa   = vm_on ? dtlb_pa : v_mem_va;

    // ---- privilege / exceptions ----
    // a CSR's address bits [9:8] are the lowest privilege that may touch it
    // ... and without S-mode the S-level CSRs do not exist (except satp,
    // which an MMU with only M/U still needs)
    wire csr_no_s   = (HAS_S == 0) & (idex_csr_addr[9:8] == 2'b01) &
                      ~((MMU != 0) & (idex_csr_addr == 12'h180));
    wire v_csr_hit, vs_on;
    // csrrw always writes; csrrs/csrrc[i] only with a nonzero rs1 / uimm
    wire csr_writes = (idex_funct3[1:0] == 2'b01) | (idex_rs1 != 5'd0);
    wire csr_bad    = idex_is_csr & ((idex_csr_addr[9:8] > cur_priv) | csr_no_s |
                                     (idex_csr_addr[11:10] == 2'b11 & csr_writes) |  // read-only (vl, vtype, vlenb, ...)
                                     (v_csr_hit & (~vs_on | (V_EXT == 0))));
    wire v_illegal;
    wire ex_illegal = idex_illegal | csr_bad | (idex_vec & v_illegal) |
                      (idex_is_mret & ~in_m) |
                      (idex_sret & ((HAS_S == 0) | in_user)) |
                      (in_user & idex_sfence);
    wire [31:0] csr_rdata_s, trap_vector, mepc_out, sepc_out, irq_cause;
    wire        irq_pending;
    wire [31:0] csr_wsrc = idex_funct3[2] ? {27'b0, idex_rs1} : opA;

    // A vector instruction holds EX while the unit runs it. It starts only
    // when it will not trap anyway (illegal, or a pending interrupt is taken
    // first); once started it runs to completion, and an interrupt waits
    // for the next instruction -- it is never taken on a finished vector op.
    wire v_is_cfg, v_busy, v_done, v_fault, v_writes_rd;
    wire [3:0]  v_fault_cause;
    wire [31:0] v_fault_tval, v_scalar, v_cfg_vl;
    wire v_fault_now = idex_vec & v_done & v_fault;
    wire exception = idex_ifault | ex_illegal | idex_ecall | idex_ebreak | ex_dfault | ex_daf_pma |
                     ex_misal | ex_imisal | v_fault_now;
    wire v_wait    = idex_valid & idex_vec & ~v_is_cfg & ~v_done &
                     (v_busy | (~exception & ~irq_pending));
    // FENCE.I waits in EX while the SoC writes back / invalidates its caches;
    // it asks only once MEM is not waiting, so the older stores are in
    assign fencei_req = idex_valid & idex_fencei & ~freeze;
    wire   fencei_wait = idex_valid & idex_fencei & ~fencei_ack;
    assign ex_hold = ex_dwalk | v_wait | fencei_wait | div_wait | mul_wait | xl_wait | bq_wait;   // (implies idex_valid)
    assign ex_go   = idex_valid & ~freeze & ~ex_hold;

    wire irq_take  = irq_pending & ~exception & ~idex_is_mret & ~idex_sret & ~idex_is_csr &
                     ~(idex_vec & (v_busy | v_done));
    assign take_trap = ex_go & (exception | irq_take);
    // A SYSTEM instruction (mret, sret, a CSR access, sfence.vma) is never a
    // branch, a jump or a memory access, so of `exception` only exc_sys can
    // be true for it -- the same value, without the branch-target and
    // memory-fault cones in front of the commits it gates (Step 58: those
    // reached every TLB entry through sfence_ex). mret, sret and CSR
    // accesses take no interrupt (irq_take above); sfence.vma can.
    wire exc_sys   = idex_ifault | ex_illegal | idex_ecall | idex_ebreak | v_fault_now;
    wire irq_sys   = irq_pending & ~exc_sys & ~idex_is_mret & ~idex_sret & ~idex_is_csr &
                     ~(idex_vec & (v_busy | v_done));
    // ... and none of them ever holds EX (no walk, divide, multiply or
    // second lookup cycle is theirs), so with XLATE_2C their commits wait
    // only for freeze, not for ex_hold and the walker state behind it
    wire sys_go    = (XLATE_2C != 0) ? (idex_valid & ~freeze) : ex_go;
    wire mret_ex   = sys_go & idex_is_mret & ~exc_sys;
    wire sret_ex   = sys_go & idex_sret    & ~exc_sys;
    wire csr_commit= sys_go & idex_is_csr  & ~exc_sys;
    wire sfence_ex = sys_go & idex_sfence  & ~(exc_sys | irq_sys);
`ifndef SYNTHESIS
    always @(posedge clk)
        if (!rst && idex_valid && (idex_is_mret | idex_sret | idex_is_csr | idex_sfence) && ex_hold) begin
            $display("a SYSTEM instruction held EX at pc %h", idex_pc);
            $finish;
        end
`endif
    // IF_PAGE: drop the registered page translation whenever its answer may
    // have changed; else, off the page, register a finished lookup
    // (the copy itself loads regardless: only valid looks at the late drop)
    // D_PAGE (Step 61): the page of the last load / store (dp_*), as
    // XLATE_2C's cycle A translated it. A load or store whose base register
    // needs no forwarding has its exact address in ID already (the register
    // file's value + the immediate); if that is in the same page, its
    // translation is taken from the copy there, registered with it (pg_*),
    // and it spends one cycle in EX instead of two. The source is the
    // lookup finishing in EX this cycle if there is one, else dp_*. Both
    // are dropped on whatever can change a translation's answer (a CSR
    // write, a trap, mret / sret, sfence.vma). The region check is done in
    // ID too, on the full address (regions can be smaller than a page).
    reg         dp_valid;
    reg  [19:0] dp_vpn, dp_ppn;
    reg  [3:0]  dp_perm;
    wire        pg_inval = csr_commit | take_trap | mret_ex | sret_ex | sfence_ex;
    wire        dp_we    = (D_PAGE != 0) & (XLATE_2C != 0) & xl_have & ex_mem & ~ex_misal &
                           (xl_hit | ~vm_on);
    wire [19:0] s_vpn    = dp_we ? xl_va[31:12]  : dp_vpn;
    wire [19:0] s_ppn    = dp_we ? xl_epa[31:12] : dp_ppn;
    wire [3:0]  s_perm   = dp_we ? xl_perm       : dp_perm;
    wire [31:0] id_va    = rs1_data_id + imm_id;
    wire        id_ldst  = (c_mem_read | c_mem_write) & ~id_is_amo & ~id_vec;
    wire        id_misal = (funct3_id[1:0] == 2'b01) ? id_va[0] :
                           (funct3_id[1:0] == 2'b10) ? (id_va[1:0] != 2'b00) : 1'b0;
    // the base is exact in ID unless the instruction in EX or MEM writes it
    wire        id_fwd   = (rs1_id != 5'd0) & ((rs1_id == idex_rd) | (rs1_id == exmem_rd));
    wire        id_pg    = (dp_we | dp_valid) & id_ldst & ~id_misal & ~id_fwd & (id_va[31:12] == s_vpn);
    always @(posedge clk) begin
        if (rst || pg_inval)  dp_valid <= 1'b0;
        else if (dp_we)       dp_valid <= 1'b1;
        if (dp_we) begin dp_vpn <= xl_va[31:12]; dp_ppn <= xl_epa[31:12]; dp_perm <= xl_perm; end
        // with ID/EX: load, or hold
        if (rst)                         pg_q <= 1'b0;
        else if (!freeze && !ex_hold)    pg_q <= (D_PAGE != 0) & id_pg & ~pg_inval;
        if (!freeze && !ex_hold) begin
            pg_va <= id_va; pg_ppn <= s_ppn; pg_perm <= s_perm; pg_pma <= pma({s_ppn, id_va[11:0]});
        end
    end
`ifndef SYNTHESIS
    // simulation only: a load / store translated in ID must have the address
    // EX computes, and the translation the D-TLB gives now (if it still holds it)
    always @(posedge clk)
        if (!rst && ex_go && ex_mem && pg_on &&
            (pg_va != ex_va_live || (vm_on && dtlb_hit && (dtlb_pa[31:12] != pg_ppn || dtlb_perm != pg_perm)) ||
             (!vm_on && pg_ppn != pg_va[31:12]) || pg_pma != pma(ex_pa))) begin
            $display("D_PAGE: the translation made in ID is wrong at pc %h (va %h, EX %h)", idex_pc, pg_va, ex_va_live);
            $finish;
        end
`endif

    wire ip_load = IF_PAGE && !ip_hit && !if_walk_l;
    always @(posedge clk) begin
        if (rst || csr_commit || take_trap || mret_ex || sret_ex || sfence_ex || ptw_fill || ptw_fault)
            ip_valid <= 1'b0;
        else if (ip_load)
            ip_valid <= 1'b1;
        if (ip_load) begin
            ip_vpn <= pc[31:12]; ip_ppn <= i_addr_l[31:12];
            ip_pf  <= if_pfault_l; ip_waf <= ~itlb_hit & wres_af;
        end
    end
`ifndef SYNTHESIS
    // simulation only: the registered page translation, wherever it is used,
    // must be what the live lookup says now (else an invalidation is missing)
    always @(posedge clk)
        if (IF_PAGE != 0 && !rst && ip_hit &&
            (if_walk_l || ip_ppn != i_addr_l[31:12] || ip_pf != if_pfault_l ||
             (ip_pf && ip_waf != (~itlb_hit & wres_af)))) begin
            $display("IF_PAGE: stale page translation at pc %h", pc);
            $finish;
        end
`endif

    wire [31:0] trap_cause = idex_ifault ? (idex_iaf ? 32'd1 : 32'd12) :
                             ex_illegal  ? 32'd2  :
                             idex_ecall  ? (in_user ? 32'd8 : in_m ? 32'd11 : 32'd9) :
                             idex_ebreak ? 32'd3  :
                             ex_imisal   ? 32'd0  :
                             ex_misal    ? (need_w ? 32'd6  : 32'd4)  :
                             ex_daf      ? (need_w ? 32'd7  : 32'd5)  :
                             ex_dfault   ? (need_w ? 32'd15 : 32'd13) :
                             v_fault_now ? {28'd0, v_fault_cause} :
                                           irq_cause;
    // mtval / stval: the faulting VA, the bad instruction, or the PC
    wire        tv_hi_sel  = idex_ifault | ex_illegal | idex_ebreak;
    wire [31:0] tv_hi      = ex_illegal ? idex_instr : idex_pc;
    wire [31:0] tv_lo      = (ex_misal | ex_dfault | ex_daf) ? ex_va :
                             v_fault_now ? v_fault_tval : 32'd0;
    wire [31:0] trap_val   = tv_hi_sel ? tv_hi : ex_imisal ? ex_target : tv_lo;
    // LATE_TVAL (XLATE_2C): csr_s writes mtval / stval a cycle after the
    // trap, so the pieces are registered apart -- the misaligned target
    // straight from the adders, beside them -- and put together then
    reg         tvh_sel_q, tv_im_q;
    reg  [31:0] tvh_q, tvl_q, tvt_q;
    always @(posedge clk) begin
        tvh_sel_q <= tv_hi_sel; tvh_q <= tv_hi; tv_im_q <= ex_imisal;
        tvt_q <= ex_target; tvl_q <= tv_lo;
    end
    wire [31:0] trap_val_late = tvh_sel_q ? tvh_q : tv_im_q ? tvt_q : tvl_q;

    csr_s #(.HAS_S(HAS_S), .HAS_U(HAS_U), .HAS_SATP(MMU), .HAS_V(V_EXT), .LATE_TVAL(XLATE_2C)) u_csr (
        .clk(clk), .rst(rst),
        .csr_addr(idex_csr_addr), .csr_funct3(idex_funct3), .csr_wsrc(csr_wsrc),
        .csr_we(csr_commit & ~v_csr_hit), .csr_rdata(csr_rdata_s),
        .pc(idex_pc), .timer_irq(timer_irq), .ext_irq(meip), .s_ext_irq(seip),
        .instr_is_mret(mret_ex), .instr_is_sret(sret_ex),
        .take_trap(take_trap), .trap_cause(trap_cause), .trap_val(trap_val), .trap_val_late(trap_val_late),
        .trap_vector(trap_vector), .mret_target(mepc_out), .sret_target(sepc_out),
        .irq_pending(irq_pending), .irq_cause(irq_cause), .deleg_now(),
        .status_sum(st_sum), .status_mxr(st_mxr),
        .status_vs(st_vs), .set_vs_dirty(v_vs_dirty),
        .cur_priv(cur_priv), .satp_out(satp_val)
    );

    assign tlb_flush_all = sfence_ex & (idex_rs1 == 5'd0);
    assign tlb_flush_one = sfence_ex & (idex_rs1 != 5'd0);
    assign tlb_flush_va  = opA;

    // ---- check the IF-stage prediction against what EX resolved ----
    wire ex_ctrl   = idex_branch | idex_jump | idex_jalr;
    // BPRED = 2: the target compare without an adder in front of it, from
    // what ID worked out: a branch's or jal's target is pc + imm, all known
    // in ID; a jalr lands on the prediction exactly when rs1 is it minus imm
    // (an odd rs1 that would also land there only counts as a miss)
    wire tgt_ok    = (BPRED != 2)  ? (ex_target == idex_pred_target) :
                     idex_jalr     ? (opA == idex_jx) : idex_tgt_ok;
    wire mispred   = ex_ctrl ? ((ex_taken != idex_pred_taken) | (ex_taken & ~tgt_ok))
                             : idex_pred_taken;          // "taken" on a non-branch
`ifndef SYNTHESIS
    always @(posedge clk)
        if (BPRED == 2 && !rst && ex_go && ex_ctrl && ex_taken && tgt_ok && ex_target != idex_pred_target) begin
            $display("BPRED: target compare wrong at pc %h", idex_pc);
            $finish;
        end
`endif
    assign bp_upd_en     = ex_go & ex_ctrl & ~take_trap;
    assign bp_upd_pc     = idex_pc;
    assign bp_upd_taken  = ex_taken;
    assign bp_upd_jump   = idex_jump | idex_jalr;
    assign bp_upd_target = ex_target;
    assign bp_upd_info   = idex_bp_info;

    // fence.i: refetch everything younger (its pc4 is the not-taken target)
    wire br_late = (REG_REDIRECT != 0) & ex_go & mispred & ~take_trap;
    assign redirect    = take_trap | mret_ex | sret_ex |
                         (ex_go & ((mispred & (REG_REDIRECT == 0)) | idex_fencei));
    assign redirect_pc = take_trap ? trap_vector :
                         mret_ex   ? mepc_out    :
                         sret_ex   ? sepc_out    :
                         (ex_taken & (REG_REDIRECT == 0)) ? ex_target : pc4_ex;
    // REG_REDIRECT: the branch leaves EX; next cycle it is in MEM, and the
    // instruction behind it in EX does nothing (idex_valid) while the PC moves
    always @(posedge clk)
        if (rst)          begin rr_valid <= 1'b0; rr_pc <= 32'd0; end
        else if (!freeze) begin rr_valid <= br_late; rr_pc <= ex_taken ? ex_target : pc4_ex; end

    // ---- vector unit (Step 47) ----
    wire [31:0] v_csr_rdata, v_mem_wdata;
    wire [3:0]  v_mem_be;
    wire        v_mem_req, v_mem_done;
    wire        v_start = v_wait & ~v_busy & ~m_port & ~ptw_busy & ~halt;
    wire        v_cfg_commit = ex_go & idex_vec & v_is_cfg & ~take_trap;
    function [31:0] csrnx; input [31:0] old, src; input [2:0] f;
        csrnx = (f[1:0] == 2'b01) ? src : (f[1:0] == 2'b10) ? (old | src) :
                (f[1:0] == 2'b11) ? (old & ~src) : old;
    endfunction
    assign vs_on = (st_vs != 2'b00);
    generate if (V_EXT) begin : g_vec
        vec_unit #(.VLEN(VLEN)) u_vec (
            .clk(clk), .rst(rst),
            .instr(idex_instr), .start(v_start), .rs1_val(opA), .rs2_val(opB),
            .is_vec(), .is_cfg(v_is_cfg), .illegal(v_illegal), .writes_rd(v_writes_rd),
            .busy(v_busy), .done(v_done), .fault(v_fault), .fault_cause(v_fault_cause),
            .fault_tval(v_fault_tval), .scalar_out(v_scalar), .vs_dirty(v_vs_dirty),
            .cfg_new_vl(v_cfg_vl), .cfg_commit(v_cfg_commit), .vs_on(vs_on),
            .csr_addr(idex_csr_addr), .csr_hit(v_csr_hit), .csr_rdata(v_csr_rdata),
            .csr_we(csr_commit & v_csr_hit),
            .csr_wdata(csrnx(v_csr_rdata, csr_wsrc, idex_funct3)),
            .mem_va(v_mem_va), .mem_store(v_mem_store), .mem_active(v_mem_active),
            .mem_want(v_mem_want), .mem_req(v_mem_req), .mem_be(v_mem_be), .mem_wdata(v_mem_wdata),
            .mem_rdata(d_rdata), .mem_done(v_mem_done), .xl_ok(v_xl_ok), .xl_fault(v_xl_fault));
    end else begin : g_novec
        assign v_is_cfg = 1'b0; assign v_illegal = 1'b1; assign v_writes_rd = 1'b0;
        assign v_busy = 1'b0; assign v_done = 1'b0; assign v_fault = 1'b0;
        assign v_fault_cause = 4'd0; assign v_fault_tval = 32'd0; assign v_scalar = 32'd0;
        assign v_vs_dirty = 1'b0; assign v_cfg_vl = 32'd0; assign v_csr_hit = 1'b0;
        assign v_csr_rdata = 32'd0; assign v_mem_va = 32'd0; assign v_mem_store = 1'b0;
        assign v_mem_active = 1'b0; assign v_mem_want = 1'b0; assign v_mem_req = 1'b0;
        assign v_mem_be = 4'd0; assign v_mem_wdata = 32'd0;
    end endgenerate

    // ---- performance counters (Step 48) ----
    // Zicntr: 64-bit mcycle / minstret, read in halves (mcycle B00 /
    // mcycleh B80, minstret B02 / minstreth B82) and writable from M;
    // cycle / instret (C00/C02, C80/C82) are their read-only user-level
    // shadows -- writes to those already trap above (bits [11:10] = 11).
    // Zihpm: mhpmcounter3..7 (B03..B07, +h at B83..B87; hpmcounterN at
    // C03..C07) count FIXED events; mhpmevent3..7 are not implemented
    // (read 0). Counters 3..6 say where the cycles that are not
    // instructions go. Every cycle is classified once, by what EX does:
    //   minstret  an instruction left EX
    //   3  load-use   EX holds the bubble a load's consumer left behind
    //   4  flush      EX holds a bubble a redirect (mispredict, trap) left
    //   5  fetch      EX holds a bubble the I-port left (I-cache miss)
    //   6  freeze     the whole pipe waits on the D-port (D-cache miss)
    //   7  mispredictions -- events, not cycles: each one costs 2 flush cycles
    // so cycles = instret + hpm3 + hpm4 + hpm5 + hpm6 + (the few cycles of
    // reset fill, trap entry and EX holds), exactly. A bubble is tagged
    // with its cause when it is made (ifid_why / idex_why) and counted when
    // it reaches EX, so a stall that hides another is never counted twice.
    // minstret counts an instruction when it leaves EX: every trap commits
    // in EX, so from there on it will retire -- and a csrr of instret (in
    // EX) then sees exactly the instructions older than itself, not just
    // those that already drained through MEM and WB.
    // mcountinhibit (0x320, M only): a set bit stops that counter (bit 0
    // cycle, 2 instret, 3..7 the events). Setting them all, reading, and
    // clearing them gives a consistent snapshot -- otherwise each counter
    // is read a few cycles after the last, and the stalls in between land
    // in some deltas and not others.
    // time / timeh (C01 / C81) read the mtime input (Step 49): read-only,
    // like the other user aliases, and there is no mtime CSR behind them.
    // There is no mcounteren: U and S may always read them. All count from
    // reset and stop while the SoC is halted; a CSR write wins over that
    // cycle's increment, as the spec says.
    wire [31:0] cnt_rdata;
    wire        cnt_hit;
    generate if (ZICNTR) begin : g_cnt
        localparam WHY_OTHER = 2'd0, WHY_LU = 2'd1, WHY_FLUSH = 2'd2, WHY_FETCH = 2'd3;
        reg  [1:0]  ifid_why, idex_why;
        always @(posedge clk)                    // mirrors the IF/ID and ID/EX updates
            if (rst) begin
                ifid_why <= WHY_OTHER; idex_why <= WHY_OTHER;
            end else begin
                if (flush && !freeze)                  ifid_why <= WHY_FLUSH;
                else if (!freeze && !front_hold && !if_ok) ifid_why <= WHY_FETCH;
                if (!freeze && !ex_hold && (flush || load_use))
                    idex_why <= flush ? WHY_FLUSH : WHY_LU;
                else if (!freeze && !ex_hold)          idex_why <= ifid_why;
            end

        reg  [63:0] cnt [0:7];                    // [1] (time) is unused
        wire [11:0] ca  = idex_csr_addr;
        wire [2:0]  idx = ca[2:0];
        reg  [7:0]  inhibit;                      // mcountinhibit (bit 1 hardwired 0)
        wire        is_inh = (ca == 12'h320);
        wire        is_cnt = ((ca[11:8] == 4'hB) | (ca[11:8] == 4'hC)) & (ca[6:3] == 4'd0) &
                             (idx != 3'd1);
        wire        is_time = (ca == 12'hC01) | (ca == 12'hC81);
        assign cnt_hit = is_cnt | is_inh | is_time;
        wire [63:0] cnt_sel = cnt[idx];
        assign cnt_rdata = is_inh  ? {24'd0, inhibit} :
                           is_time ? (ca[7] ? mtime[63:32] : mtime[31:0]) :
                           ca[7]   ? cnt_sel[63:32] : cnt_sel[31:0];
        wire        cnt_we  = csr_commit & is_cnt & (ca[11:8] == 4'hB);
        wire [31:0] cnt_new = csrnx(cnt_rdata, csr_wsrc, idex_funct3);
        always @(posedge clk)
            if (rst)                         inhibit <= 8'd0;
            else if (csr_commit & is_inh)    inhibit <= cnt_new[7:0] & 8'b1111_1101;
        wire        bubble  = ~freeze & ~ex_hold & ~idex_valid;
        wire [7:0]  ev;
        assign ev[0] = 1'b1;                                          // cycle
        assign ev[1] = 1'b0;
        assign ev[2] = ex_go & ~take_trap;                            // instret
        assign ev[3] = bubble & (idex_why == WHY_LU);
        assign ev[4] = bubble & (idex_why == WHY_FLUSH);
        assign ev[5] = bubble & (idex_why == WHY_FETCH);
        assign ev[6] = freeze & ~halt;
        assign ev[7] = ex_go & mispred & ~take_trap;
        // HPM_LATE: events 3..7 (implementation-defined) through a register,
        // so a stall decided late in the cycle reaches 5 flip-flops, not 320
        reg  [7:3]  ev_q;
        always @(posedge clk) ev_q <= rst ? 5'd0 : ev[7:3];
        wire [7:0]  ev_c = (HPM_LATE != 0) ? {ev_q, ev[2:0]} : ev;
        integer n;
        always @(posedge clk)
            for (n = 0; n < 8; n = n + 1)
                if (rst || n == 1) cnt[n] <= 64'd0;
                else if (cnt_we && idx == n && ca[7]) cnt[n][63:32] <= cnt_new;
                else if (cnt_we && idx == n)          cnt[n][31:0]  <= cnt_new;
                else if (ev_c[n] && !halt && !inhibit[n]) cnt[n] <= cnt[n] + 64'd1;
    end else begin : g_nocnt
        assign cnt_hit = 1'b0; assign cnt_rdata = 32'd0;
    end endgenerate
    wire [31:0] csr_rdata = v_csr_hit ? v_csr_rdata : cnt_hit ? cnt_rdata : csr_rdata_s;

    // ---- bit manipulation (Step 46): beside the ALU, picked when it hit ----
    wire [31:0] zb_result;
    zb_unit #(.ZBA(ZBA), .ZBB(ZBB), .ZBC(ZBC), .ZBS(ZBS)) u_zb (
        .opcode(idex_opcode), .funct3(idex_funct3), .funct7(idex_funct7), .rs2f(idex_rs2),
        .a(opA), .b(alu_b), .hit(), .result(zb_result));

    wire [31:0] ex_result = idex_is_csr           ? csr_rdata :
                            idex_vec              ? (v_is_cfg ? v_cfg_vl : v_scalar) :
                            idex_zb               ? zb_result :
                            (idex_wb_sel==WB_PC4)  ? pc4_ex    :
                            (idex_wb_sel==WB_IMM)  ? idex_imm  : alu_result;
    wire ex_keep = ex_go & ~take_trap;        // instruction moves on to MEM

    // EX/MEM register
    reg [31:0] exmem_addr, exmem_store; reg [2:0] exmem_funct3;
    reg [4:0]  exmem_amo_f5;
    reg [1:0]  exmem_wb_sel;
    reg        exmem_mem_read, exmem_mem_write, exmem_lr, exmem_sc, exmem_rmw, exmem_valid;
    always @(posedge clk) begin
        // VALID_FLUSH: a bubble clears only the control bits below, the
        // rest load anyway, so ex_keep drives 7 flip-flops, not every reset
        if (rst || (VALID_FLUSH == 0 && !freeze && !ex_keep)) begin  // bubble (incl. ex_hold)
            exmem_reg_write<=0; exmem_mem_read<=0; exmem_mem_write<=0;
            exmem_lr<=0; exmem_sc<=0; exmem_rmw<=0; exmem_valid<=0;
            exmem_rd<=0; exmem_result<=0; exmem_addr<=0; exmem_store<=0;
            exmem_funct3<=0; exmem_wb_sel<=WB_ALU; exmem_amo_f5<=0;
        end else if (!freeze) begin
            exmem_reg_write<=ex_keep & (idex_is_csr | idex_reg_write | (idex_vec & v_writes_rd));
            exmem_mem_read<=ex_keep & idex_mem_read; exmem_mem_write<=ex_keep & idex_mem_write;
            exmem_lr<=ex_keep & idex_lr; exmem_sc<=ex_keep & idex_sc; exmem_rmw<=ex_keep & idex_rmw;
            exmem_valid<=ex_keep; exmem_rd<=idex_rd;
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

    // the vector unit only runs while MEM is empty (its instruction holds EX)
    wire v_req_g    = v_mem_req & ~ptw_busy & ~halt;
    assign v_mem_done = v_req_g & d_ready;
    assign d_addr  = ptw_busy ? ptw_addr : v_mem_active ? v_pa : exmem_addr;
    // the next D-port address: the load / store in EX, about to enter MEM
    // (a walk, the vector unit or an AMO's second half guess wrong -- a cycle)
    assign d_addr_next = ex_pa;          // (XLATE_2C: from registers)
    wire [2:0] ptw_pma = pma(ptw_addr);
    wire   ptw_mem_ok = ptw_pma[0];
    assign d_req   = (ptw_req & ptw_mem_ok) | v_req_g | m_req;
    assign d_we    = ptw_busy ? 4'b0000 :
                     v_mem_active ? (v_mem_store ? v_mem_be : 4'b0000) :
                     (m_write ? (exmem_rmw ? 4'b1111 : st_mask) : 4'b0000);
    assign d_wdata = v_mem_active ? v_mem_wdata : exmem_rmw ? amo_new : st_data;

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
    wire ptw_start_d = (ex_dwalk | v_walk) & ~m_port & ~halt;
    // (XLATE_2C: a fetch walk does not start while a load / store is in EX,
    //  so the D-port promise below need not wait for the fetch side)
    wire ptw_start_i = if_walk & ~m_port & ~flush & ~halt &
                       ~((XLATE_2C != 0) & idex_valid & (idex_mem_read | idex_mem_write));
    // the D-port hint is a promise when the load / store in EX moves to MEM
    // and no walk holds or takes the port: MEM asks at exactly ex_pa
    assign d_hint_ok = (XLATE_2C != 0) & ex_keep & (idex_mem_read | idex_mem_write) &
                       ~ptw_busy & ~ptw_start_d;
    generate if (MMU) begin : g_ptw
        ptw #(.SVADE(SVADE), .LATE_KILL(XLATE_2C), .REG_RESULT(XLATE_2C)) u_ptw (
            .clk(clk), .rst(rst), .satp(satp_val),
            .start_d(ptw_start_d), .va_d(dtlb_va),
            .start_i(ptw_start_i), .va_i(pc),
            .kill(flush),
            .busy(ptw_busy), .mem_req(ptw_req), .mem_addr(ptw_addr), .mem_rdata(d_rdata), .mem_ready(d_ready),
            .mem_ok(ptw_mem_ok),
            .done_fill(ptw_fill), .done_fault(ptw_fault), .done_af(ptw_af),
            .side_i(ptw_side_i), .va(ptw_va),
            .leaf_ppn(ptw_ppn), .leaf_super(ptw_super), .leaf_perm(ptw_perm)
        );
    end else begin : g_no_ptw
        assign ptw_busy = 1'b0; assign ptw_req = 1'b0; assign ptw_addr = 32'd0; assign ptw_fill = 1'b0;
        assign ptw_fault = 1'b0; assign ptw_af = 1'b0; assign ptw_side_i = 1'b0; assign ptw_va = 32'd0;
        assign ptw_ppn = 22'd0; assign ptw_super = 1'b0; assign ptw_perm = 4'd0;
    end endgenerate

    always @(posedge clk) begin
        if (rst || take_trap || sfence_ex) begin wres_valid <= 1'b0; wres_af <= 1'b0; end
        else if (ptw_fault) begin
            wres_valid <= 1'b1; wres_i <= ptw_side_i; wres_vpn <= ptw_va[31:12]; wres_af <= ptw_af;
        end else if (ptw_fill && ptw_va[31:12] == wres_vpn && ptw_side_i == wres_i)
            wres_valid <= 1'b0;
    end
endmodule

`default_nettype wire
