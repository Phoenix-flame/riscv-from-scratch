// =====================================================================
// s6_core.v  -  Tiny RV32IMAC_Zicsr_Zicntr core (M+U) for Spartan-6 LX9
// ---------------------------------------------------------------------
// The design brief was "as many features as will fit in an XC6SLX9", so
// this is a *multi-cycle* core: one shared 32-bit ALU, one shared 33-bit
// add/sub in the mul/div unit, a distributed-RAM register file, and a
// state machine instead of pipeline registers and forwarding paths. What
// that buys is headroom to spend on architecture instead of throughput:
//
//   RV32I      the base integer ISA
//   M          mul/div/rem, sequential (or DSP48A1-backed, see MUL_DSP)
//   A          lr.w / sc.w and the nine AMOs (single hart reservation)
//   C          16-bit instructions, including word-straddling fetch
//   Zicsr      the machine CSR file
//   Zicntr     mcycle / minstret / time (64-bit)
//   M + U      two privilege levels, mstatus/mepc/mcause/mtval, mret
//   traps      illegal instruction, ecall, ebreak, misaligned load/store,
//              misaligned jump target, and the three machine interrupts
//              (external / software / timer), direct AND vectored mtvec
//   wfi        real sleep: the FSM parks until an enabled interrupt fires
//
// Every extension is a parameter, so the same file also builds a bare
// RV32I core when the LUTs run out.
//
// ---- the fetch pipeline -------------------------------------------------
// The instruction bus is a block RAM: present a word address, get the word
// one cycle later. With FAST_FETCH=1 the address for the *next* instruction
// is presented during the cycle that finishes the current one, so a plain
// ALU instruction is one cycle and only loads, stores to slow slaves,
// mul/div and AMOs cost extra. Set FAST_FETCH=0 to insert a separate FETCH
// state instead: two cycles per instruction, but the next-PC mux drops out
// of the block RAM address path, which is worth ~20% Fmax.
//
// The C extension makes fetch interesting: the PC is halfword-aligned, so
// a 32-bit instruction sitting at pc[1]==1 straddles two ROM words. The
// EXEC cycle that discovers this commits nothing, latches the low half and
// -- in the same cycle -- presents word N+1, so the straddle costs exactly
// one extra cycle. (Same trick as rtl/cpu_mc_c.v in the parent tutorial.)
//
// ---- the data bus ------------------------------------------------------
// Word address + 4-bit byte-write mask + registered read, plus a `ready`
// input so slow slaves (the board's 8-bit asynchronous SRAM) can stall the
// core. Block RAM and the peripherals tie ready high. The core holds
// addr/we/re stable until it sees ready, and a slave that needs many
// cycles must latch the request on the first one and ignore it after.
// =====================================================================
`default_nettype none

module s6_core #(
    parameter [31:0] RESET_ADDR = 32'h0000_0000,
    parameter        ENABLE_M   = 1,       // mul / div / rem
    parameter        ENABLE_A   = 1,       // lr / sc / amo
    parameter        ENABLE_C   = 1,       // compressed instructions
    parameter        ENABLE_U   = 1,       // user mode
    parameter        MUL_DSP    = 0,       // 1: 1-cycle multiply on DSP48A1
    parameter        FAST_FETCH = 1,       // 1: overlap fetch with execute
    parameter [31:0] HART_ID    = 32'd0
) (
    input  wire        clk,
    input  wire        rst,

    // ---- instruction bus (registered read, 32-bit words) ----
    output wire [31:0] ibus_addr,
    input  wire [31:0] ibus_rdata,

    // ---- data bus ----
    output wire [31:0] dbus_addr,
    output wire [3:0]  dbus_we,
    output wire        dbus_re,
    output wire [31:0] dbus_wdata,
    input  wire [31:0] dbus_rdata,
    input  wire        dbus_ready,

    // ---- system ----
    input  wire        timer_irq,
    input  wire        soft_irq,
    input  wire        ext_irq,
    input  wire [63:0] mtime,          // the CLINT's real-time counter -> `time`
    input  wire        halt,

    // ---- observation ----
    output wire [31:0] pc_out,
    output wire [31:0] instr_out,
    output wire        retire_out
);
    localparam [31:0] MISA_VAL = 32'h4000_0100                     // MXL=32, I
                               | (ENABLE_M ? 32'h0000_1000 : 32'd0)
                               | (ENABLE_A ? 32'h0000_0001 : 32'd0)
                               | (ENABLE_C ? 32'h0000_0004 : 32'd0)
                               | (ENABLE_U ? 32'h0010_0000 : 32'd0);

    localparam S_FETCH = 4'd0, S_EXEC  = 4'd1, S_LOAD  = 4'd2, S_STORE = 4'd3,
               S_MD    = 4'd4, S_AMO_L = 4'd5, S_AMO_S = 4'd6, S_WFI   = 4'd7,
               S_HALT  = 4'd8;
    // where an instruction goes when it finishes
    localparam [3:0] S_DONE = FAST_FETCH ? S_EXEC : S_FETCH;

    reg [3:0]  state;
    reg [31:0] pc;

    // =====================================================================
    // Fetch: halfword-aligned PC over a 32-bit word memory
    // =====================================================================
    reg         straddle_q;              // executing a word-straddling instr
    reg  [15:0] lo_half;                 // ... its low 16 bits (from word N)

    wire [31:0] pc_word = {pc[31:2], 2'b00};
    wire        in_exec = (state == S_EXEC) & ~halt;

    wire [15:0] raw16   = pc[1] ? ibus_rdata[31:16] : ibus_rdata[15:0];
    wire        is_c    = (ENABLE_C != 0) & ~straddle_q & (raw16[1:0] != 2'b11);
    wire        need_hi = (ENABLE_C != 0) & ~straddle_q & pc[1] & (raw16[1:0] == 2'b11);

    wire        fetch_hi_now = in_exec & need_hi;   // discovery cycle
    wire        commit       = in_exec & ~need_hi;  // a real execute cycle

    wire [31:0] c_expanded;
    wire        c_illegal;
    generate
        if (ENABLE_C) begin : g_rvc
            s6_rvc u_rvc (.c(raw16), .instr32(c_expanded), .illegal(c_illegal));
        end else begin : g_no_rvc
            assign c_expanded = 32'h0000_0013;
            assign c_illegal  = 1'b0;
        end
    endgenerate

    wire [31:0] instr = straddle_q ? {ibus_rdata[15:0], lo_half} :
                        is_c       ? c_expanded :
                                     ibus_rdata;

    // =====================================================================
    // Decode
    // =====================================================================
    wire [6:0] opcode = instr[6:0];
    wire [4:0] rd_a   = instr[11:7];
    wire [2:0] f3     = instr[14:12];
    wire [4:0] rs1_a  = instr[19:15];
    wire [4:0] rs2_a  = instr[24:20];
    wire [6:0] f7     = instr[31:25];
    wire [11:0] f12   = instr[31:20];
    wire [4:0] amo_f5 = instr[31:27];

    wire is_load   = (opcode == 7'b0000011);
    wire is_store  = (opcode == 7'b0100011);
    wire is_opimm  = (opcode == 7'b0010011);
    wire is_op     = (opcode == 7'b0110011);
    wire is_lui    = (opcode == 7'b0110111);
    wire is_auipc  = (opcode == 7'b0010111);
    wire is_jal    = (opcode == 7'b1101111);
    wire is_jalr   = (opcode == 7'b1100111) & (f3 == 3'b000);
    wire is_branch = (opcode == 7'b1100011);
    wire is_system = (opcode == 7'b1110011);
    wire is_fence  = (opcode == 7'b0001111);

    wire is_muldiv = (ENABLE_M != 0) & is_op & (f7 == 7'b0000001);

    // ---- A extension ----
    wire is_amoop  = (ENABLE_A != 0) & (opcode == 7'b0101111) & (f3 == 3'b010);
    wire is_lr     = is_amoop & (amo_f5 == 5'b00010) & (rs2_a == 5'd0);
    wire is_sc     = is_amoop & (amo_f5 == 5'b00011);
    wire amo_rmw_ok= (amo_f5 == 5'b00000) | (amo_f5 == 5'b00001) | (amo_f5 == 5'b00100) |
                     (amo_f5 == 5'b01000) | (amo_f5 == 5'b01100) | (amo_f5 == 5'b10000) |
                     (amo_f5 == 5'b10100) | (amo_f5 == 5'b11000) | (amo_f5 == 5'b11100);
    wire is_amo_rmw= is_amoop & amo_rmw_ok;
    wire is_amo    = is_lr | is_sc | is_amo_rmw;

    // ---- SYSTEM ----
    wire is_csr    = is_system & (f3 != 3'b000) & (f3 != 3'b100);
    wire sys_plain = is_system & (f3 == 3'b000) & (rs1_a == 5'd0) & (rd_a == 5'd0);
    wire is_ecall  = sys_plain & (f12 == 12'h000);
    wire is_ebreak = sys_plain & (f12 == 12'h001);
    wire is_mret   = sys_plain & (f12 == 12'h302);
    wire is_wfi    = sys_plain & (f12 == 12'h105);

    // ---- immediates ----
    wire [31:0] imm_i = {{20{instr[31]}}, instr[31:20]};
    wire [31:0] imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    wire [31:0] imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25],
                         instr[11:8], 1'b0};
    wire [31:0] imm_u = {instr[31:12], 12'b0};
    wire [31:0] imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20],
                         instr[30:21], 1'b0};
    reg  [31:0] imm;
    always @(*) begin
        case (opcode)
            7'b0100011: imm = imm_s;                        // store
            7'b1100011: imm = imm_b;                        // branch
            7'b0110111, 7'b0010111: imm = imm_u;            // lui / auipc
            7'b1101111: imm = imm_j;                        // jal
            default:    imm = imm_i;
        endcase
    end

    // =====================================================================
    // Register file
    // =====================================================================
    reg  [31:0] wb_data;
    reg         rf_we;
    wire [31:0] rs1_data, rs2_data;
    s6_regfile u_rf (
        .clk(clk), .we(rf_we),
        .rs1_addr(rs1_a), .rs2_addr(rs2_a),
        .rd_addr(rd_a),   .rd_data(wb_data),
        .rs1_data(rs1_data), .rs2_data(rs2_data)
    );

    // =====================================================================
    // ALU (one adder, one barrel shifter, one 33-bit comparator)
    // =====================================================================
    localparam A_ADD =4'd0,  A_SUB =4'd1,  A_SLL =4'd2,  A_SLT =4'd3,
               A_SLTU=4'd4,  A_XOR =4'd5,  A_SRL =4'd6,  A_SRA =4'd7,
               A_OR  =4'd8,  A_AND =4'd9,  A_BSEL=4'd10, A_MIN =4'd11,
               A_MAX =4'd12, A_MINU=4'd13, A_MAXU=4'd14;

    wire        amo_exec = (state == S_AMO_S);       // the read-modify-write cycle
    reg  [31:0] amo_val;                             // the value AMO read back

    wire [31:0] alu_a = amo_exec ? amo_val : rs1_data;
    wire [31:0] alu_b = (is_op | is_branch | is_amo) ? rs2_data : imm;

    reg [3:0] alu_op;
    always @(*) begin
        if (amo_exec) begin
            case (amo_f5)
                5'b00000: alu_op = A_ADD;            // amoadd
                5'b00001: alu_op = A_BSEL;           // amoswap
                5'b00100: alu_op = A_XOR;
                5'b01000: alu_op = A_OR;
                5'b01100: alu_op = A_AND;
                5'b10000: alu_op = A_MIN;
                5'b10100: alu_op = A_MAX;
                5'b11000: alu_op = A_MINU;
                default:  alu_op = A_MAXU;
            endcase
        end else if (is_op | is_opimm) begin
            case (f3)
                3'b000:  alu_op = (is_op & f7[5]) ? A_SUB : A_ADD;
                3'b001:  alu_op = A_SLL;
                3'b010:  alu_op = A_SLT;
                3'b011:  alu_op = A_SLTU;
                3'b100:  alu_op = A_XOR;
                3'b101:  alu_op = f7[5] ? A_SRA : A_SRL;
                3'b110:  alu_op = A_OR;
                default: alu_op = A_AND;
            endcase
        end else
            alu_op = A_ADD;                          // address arithmetic
    end

    // One 33-bit subtract answers signed and unsigned "less than" alike:
    // hang the sign bit on top for the signed case, a zero for unsigned.
    wire cmp_uns = amo_exec  ? amo_f5[3] :           // amominu/amomaxu
                   is_branch ? f3[1]     :           // bltu / bgeu
                               f3[0];                // sltu / sltiu
    wire [32:0] cmp_d  = {alu_a[31] & ~cmp_uns, alu_a} - {alu_b[31] & ~cmp_uns, alu_b};
    wire        cmp_lt = cmp_d[32];
    wire        cmp_eq = (alu_a == alu_b);

    wire [4:0] shamt = alu_b[4:0];
    reg [31:0] alu_result;
    always @(*) begin
        case (alu_op)
            A_ADD:  alu_result = alu_a + alu_b;
            A_SUB:  alu_result = alu_a - alu_b;
            A_SLL:  alu_result = alu_a << shamt;
            A_SLT,
            A_SLTU: alu_result = {31'b0, cmp_lt};
            A_XOR:  alu_result = alu_a ^ alu_b;
            A_SRL:  alu_result = alu_a >> shamt;
            A_SRA:  alu_result = $signed(alu_a) >>> shamt;
            A_OR:   alu_result = alu_a | alu_b;
            A_AND:  alu_result = alu_a & alu_b;
            A_BSEL: alu_result = alu_b;
            A_MIN,
            A_MINU: alu_result = cmp_lt ? alu_a : alu_b;
            A_MAX,
            A_MAXU: alu_result = cmp_lt ? alu_b : alu_a;
            default: alu_result = alu_a + alu_b;
        endcase
    end

    // =====================================================================
    // mul / div
    // =====================================================================
    wire        md_busy, md_done;
    wire [31:0] md_result;
    wire        md_start;
    generate
        if (ENABLE_M) begin : g_muldiv
            s6_muldiv #(.MUL_DSP(MUL_DSP)) u_md (
                .clk(clk), .rst(rst), .start(md_start), .op(f3),
                .a(rs1_data), .b(rs2_data),
                .busy(md_busy), .done(md_done), .result(md_result)
            );
        end else begin : g_no_muldiv
            assign md_busy = 1'b0;
            assign md_done = 1'b1;
            assign md_result = 32'd0;
        end
    endgenerate

    // =====================================================================
    // Program counter arithmetic
    // =====================================================================
    wire [31:0] pc_incr     = pc + (is_c ? 32'd2 : 32'd4);
    wire [31:0] pc_plus_imm = pc + imm;

    reg branch_cond;
    always @(*) begin
        case (f3)
            3'b000:  branch_cond =  cmp_eq;          // beq
            3'b001:  branch_cond = ~cmp_eq;          // bne
            3'b100:  branch_cond =  cmp_lt;          // blt
            3'b101:  branch_cond = ~cmp_lt;          // bge
            3'b110:  branch_cond =  cmp_lt;          // bltu
            3'b111:  branch_cond = ~cmp_lt;          // bgeu
            default: branch_cond = 1'b0;
        endcase
    end
    wire branch_taken = is_branch & branch_cond;
    wire [31:0] jalr_tgt = {alu_result[31:1], 1'b0};
    wire [31:0] jump_tgt = is_jalr ? jalr_tgt : pc_plus_imm;
    wire        takes_jump = is_jal | is_jalr | branch_taken;

    // =====================================================================
    // Address generation, alignment checks
    // =====================================================================
    // AMOs address with rs1 alone; everything else with rs1 + immediate.
    wire [31:0] mem_addr = is_amo ? rs1_data : alu_result;
    wire [1:0]  ba       = mem_addr[1:0];
    wire        sz_half  = (f3[1:0] == 2'b01);
    wire        sz_word  = (f3[1:0] == 2'b10);
    wire        ls_bad   = (sz_half & ba[0]) | (sz_word & (ba != 2'b00));

    wire load_fault  = (is_load  & ls_bad) | (is_lr & (ba != 2'b00));
    wire store_fault = (is_store & ls_bad) | ((is_sc | is_amo_rmw) & (ba != 2'b00));
    wire instr_fault = takes_jump & (ENABLE_C ? 1'b0 : jump_tgt[1]);

    // =====================================================================
    // Legality
    // =====================================================================
    reg op_legal;
    always @(*) begin
        case (opcode)
            7'b0110111, 7'b0010111, 7'b1101111: op_legal = 1'b1;      // lui/auipc/jal
            7'b1100111: op_legal = (f3 == 3'b000);                    // jalr
            7'b1100011: op_legal = (f3 != 3'b010) & (f3 != 3'b011);
            7'b0000011: op_legal = (f3 != 3'b011) & (f3 != 3'b110) & (f3 != 3'b111);
            7'b0100011: op_legal = (f3 == 3'b000) | (f3 == 3'b001) | (f3 == 3'b010);
            7'b0010011: op_legal = (f3 == 3'b001) ? (f7 == 7'b0000000) :
                                   (f3 == 3'b101) ? (f7 == 7'b0000000 |
                                                     f7 == 7'b0100000) : 1'b1;
            7'b0110011: op_legal = (f7 == 7'b0000000) ? 1'b1 :
                                   (f7 == 7'b0100000) ? ((f3 == 3'b000) | (f3 == 3'b101)) :
                                   (f7 == 7'b0000001) ? (ENABLE_M != 0) : 1'b0;
            7'b0001111: op_legal = (f3 == 3'b000) | (f3 == 3'b001);   // fence / fence.i
            7'b1110011: op_legal = is_csr | is_ecall | is_ebreak | is_mret | is_wfi;
            7'b0101111: op_legal = (ENABLE_A != 0) & (f3 == 3'b010) &
                                   (is_lr | is_sc | is_amo_rmw);
            default:    op_legal = 1'b0;
        endcase
    end

    wire        csr_illegal;
    wire [1:0]  priv;
    wire        in_user = (priv == 2'b00);
    wire priv_violation = in_user & is_mret;
    wire illegal_instr  = (is_c & c_illegal) | ~op_legal | csr_illegal | priv_violation;

    // =====================================================================
    // Traps
    // =====================================================================
    wire        irq_pending, irq_any;
    wire [31:0] irq_cause, csr_rdata, trap_target, mepc_out;

    wire exc_any = illegal_instr | is_ecall | is_ebreak |
                   load_fault | store_fault | instr_fault;
    wire trap_now = commit & (irq_pending | exc_any);

    wire [31:0] exc_cause = illegal_instr ? 32'd2 :
                            is_ecall      ? (in_user ? 32'd8 : 32'd11) :
                            is_ebreak     ? 32'd3 :
                            load_fault    ? 32'd4 :
                            store_fault   ? 32'd6 :
                                            32'd0;   // instruction misaligned
    wire [31:0] exc_tval  = illegal_instr ? (is_c ? {16'b0, raw16} : instr) :
                            is_ebreak     ? pc :
                            (load_fault | store_fault) ? mem_addr :
                            instr_fault   ? jump_tgt : 32'd0;

    // An interrupt outranks any exception the same instruction would raise.
    wire [31:0] trap_cause = irq_pending ? irq_cause : exc_cause;
    wire [31:0] trap_tval  = irq_pending ? 32'd0     : exc_tval;

    // =====================================================================
    // CSR file
    // =====================================================================
    wire [31:0] csr_wsrc  = f3[2] ? {27'b0, rs1_a} : rs1_data;
    wire        csr_write = (f3[1:0] == 2'b01) | (rs1_a != 5'd0);

    s6_csr #(
        .HART_ID(HART_ID), .MISA_VAL(MISA_VAL),
        .ENABLE_U(ENABLE_U), .ENABLE_C(ENABLE_C)
    ) u_csr (
        .clk(clk), .rst(rst),
        .addr(f12), .f3(f3), .wsrc(csr_wsrc),
        .access(is_csr), .will_write(csr_write),
        .we(is_csr & commit & ~trap_now),
        .rdata(csr_rdata), .illegal(csr_illegal),
        .trap_take(trap_now), .trap_pc(pc),
        .trap_cause(trap_cause), .trap_tval(trap_tval),
        .mret(is_mret & commit & ~trap_now),
        .trap_target(trap_target), .mepc_out(mepc_out), .priv(priv),
        .timer_irq(timer_irq), .soft_irq(soft_irq), .ext_irq(ext_irq),
        .irq_pending(irq_pending), .irq_any(irq_any), .irq_cause(irq_cause),
        .retire(retire_out), .mtime(mtime)
    );

    // =====================================================================
    // Next PC
    // =====================================================================
    reg [31:0] next_pc;
    always @(*) begin
        if      (trap_now)      next_pc = trap_target;
        else if (is_mret)       next_pc = mepc_out;
        else if (takes_jump)    next_pc = jump_tgt;
        else                    next_pc = pc_incr;
    end

    // =====================================================================
    // lr / sc reservation (one hart: address match is enough)
    // =====================================================================
    reg        res_valid;
    reg [31:0] res_addr;
    wire       sc_ok = res_valid & (res_addr == {mem_addr[31:2], 2'b00});

    // =====================================================================
    // Data bus
    // =====================================================================
    // Byte and halfword stores replicate the source across the word; the
    // byte-write mask picks the lanes, so no shifter is needed.
    assign dbus_addr  = mem_addr;
    assign dbus_wdata = amo_exec        ? alu_result             :
                        (f3 == 3'b000)  ? {4{rs2_data[7:0]}}     :
                        (f3 == 3'b001)  ? {2{rs2_data[15:0]}}    :
                                          rs2_data;
    wire [3:0] wmask  = (f3 == 3'b000) ? (4'b0001 << ba) :
                        (f3 == 3'b001) ? (4'b0011 << ba) :
                                          4'b1111;

    wire issue_store = commit & ~trap_now & (is_store | (is_sc & sc_ok));
    wire issue_load  = commit & ~trap_now & (is_load | is_lr | is_amo_rmw);

    assign dbus_we = (issue_store | (state == S_STORE) | (state == S_AMO_S))
                     ? wmask : 4'b0000;
    assign dbus_re = issue_load | (state == S_LOAD) | (state == S_AMO_L);

    // ---- load data extraction ----
    wire [31:0] dw = dbus_rdata;
    reg  [31:0] load_val;
    always @(*) begin
        case (f3)
            3'b000: case (ba)                                  // lb
                2'd0: load_val = {{24{dw[7]}},  dw[7:0]};
                2'd1: load_val = {{24{dw[15]}}, dw[15:8]};
                2'd2: load_val = {{24{dw[23]}}, dw[23:16]};
                default: load_val = {{24{dw[31]}}, dw[31:24]};
            endcase
            3'b001: load_val = ba[1] ? {{16{dw[31]}}, dw[31:16]}     // lh
                                     : {{16{dw[15]}}, dw[15:0]};
            3'b100: case (ba)                                  // lbu
                2'd0: load_val = {24'd0, dw[7:0]};
                2'd1: load_val = {24'd0, dw[15:8]};
                2'd2: load_val = {24'd0, dw[23:16]};
                default: load_val = {24'd0, dw[31:24]};
            endcase
            3'b101: load_val = ba[1] ? {16'd0, dw[31:16]}            // lhu
                                     : {16'd0, dw[15:0]};
            default: load_val = dw;                            // lw / lr.w
        endcase
    end

    // =====================================================================
    // Write-back
    // =====================================================================
    always @(*) begin
        if      (state == S_LOAD)  wb_data = load_val;
        else if (state == S_MD)    wb_data = md_result;
        else if (state == S_AMO_S) wb_data = amo_val;
        else if (is_csr)           wb_data = csr_rdata;
        else if (is_lui)           wb_data = imm;
        else if (is_auipc)         wb_data = pc_plus_imm;
        else if (is_jal | is_jalr) wb_data = pc_incr;
        else if (is_sc)            wb_data = {31'b0, ~sc_ok};
        else                       wb_data = alu_result;
    end

    always @(*) begin
        rf_we = 1'b0;
        if      (state == S_LOAD)  rf_we = dbus_ready;
        else if (state == S_MD)    rf_we = md_done;
        else if (state == S_AMO_S) rf_we = dbus_ready;
        else if (commit & ~trap_now)
            rf_we = (is_op & ~is_muldiv) | is_opimm | is_lui | is_auipc |
                    is_jal | is_jalr | is_csr | is_sc;
    end

    // =====================================================================
    // The control FSM
    // =====================================================================
    assign md_start = commit & ~trap_now & is_muldiv;

    // Does the current cycle retire the instruction?
    reg instr_done;
    always @(*) begin
        instr_done = 1'b0;
        case (state)
            S_EXEC: if (commit) begin
                if      (trap_now)      instr_done = 1'b1;
                else if (is_wfi)        instr_done = 1'b0;      // -> S_WFI
                else if (is_muldiv)     instr_done = 1'b0;      // -> S_MD
                else if (is_load | is_lr | is_amo_rmw) instr_done = 1'b0;
                else if (is_store | (is_sc & sc_ok))   instr_done = dbus_ready;
                else                    instr_done = 1'b1;
            end
            S_LOAD, S_STORE, S_AMO_S: instr_done = dbus_ready;
            S_MD:                     instr_done = md_done;
            S_WFI:                    instr_done = irq_any;
            default:                  instr_done = 1'b0;
        endcase
    end

    wire fetch_next = (FAST_FETCH != 0) & instr_done;
    assign retire_out = instr_done & ~trap_now;
    assign pc_out     = pc;
    assign instr_out  = instr;

    assign ibus_addr = fetch_next                  ? {next_pc[31:2], 2'b00} :
                       (fetch_hi_now | straddle_q) ? (pc_word + 32'd4)      :
                                                     pc_word;

    always @(posedge clk) begin
        if (rst) begin
            state      <= S_FETCH;
            pc         <= RESET_ADDR;
            straddle_q <= 1'b0;
            lo_half    <= 16'd0;
            amo_val    <= 32'd0;
        end else if (halt) begin
            state <= S_HALT;
        end else begin
            case (state)
                S_FETCH: state <= S_EXEC;

                S_EXEC: begin
                    if (need_hi) begin                 // 32-bit instr at pc[1]==1
                        lo_half    <= ibus_rdata[31:16];
                        straddle_q <= 1'b1;
                    end else if (trap_now) begin
                        pc <= next_pc; straddle_q <= 1'b0; state <= S_DONE;
                    end else if (is_wfi) begin
                        state <= S_WFI;
                    end else if (is_muldiv) begin
                        state <= S_MD;
                    end else if (is_load | is_lr) begin
                        state <= S_LOAD;
                    end else if (is_amo_rmw) begin
                        state <= S_AMO_L;
                    end else if (is_store | (is_sc & sc_ok)) begin
                        if (dbus_ready) begin
                            pc <= next_pc; straddle_q <= 1'b0; state <= S_DONE;
                        end else
                            state <= S_STORE;
                    end else begin
                        pc <= next_pc; straddle_q <= 1'b0; state <= S_DONE;
                    end
                end

                S_LOAD, S_STORE, S_AMO_S: if (dbus_ready) begin
                    pc <= next_pc; straddle_q <= 1'b0; state <= S_DONE;
                end

                S_AMO_L: if (dbus_ready) begin
                    amo_val <= dw;
                    state   <= S_AMO_S;
                end

                S_MD: if (md_done) begin
                    pc <= next_pc; straddle_q <= 1'b0; state <= S_DONE;
                end

                // Sleep. The spec wakes WFI on any *enabled* interrupt even
                // when mstatus.MIE is clear, so this watches irq_any and lets
                // the next EXEC decide whether to actually take the trap.
                S_WFI: if (irq_any) begin
                    pc <= next_pc; straddle_q <= 1'b0; state <= S_DONE;
                end

                default: state <= S_HALT;
            endcase
        end
    end

    // ---- reservation bookkeeping ----
    wire store_hits_res = (|dbus_we) & res_valid &
                          ({dbus_addr[31:2], 2'b00} == res_addr);
    always @(posedge clk) begin
        if (rst) begin
            res_valid <= 1'b0;
            res_addr  <= 32'd0;
        end else if (trap_now) begin
            res_valid <= 1'b0;                    // a trap forfeits the reservation
        end else if ((state == S_LOAD) && dbus_ready && is_lr) begin
            res_valid <= 1'b1;
            res_addr  <= {mem_addr[31:2], 2'b00};
        end else if (commit & is_sc) begin
            res_valid <= 1'b0;                    // sc always clears it, pass or fail
        end else if (store_hits_res) begin
            res_valid <= 1'b0;
        end
    end
endmodule

`default_nettype wire
