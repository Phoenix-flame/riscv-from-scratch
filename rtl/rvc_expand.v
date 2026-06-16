// =====================================================================
// rvc_expand.v  -  RVC (compressed) decoder: 16-bit -> 32-bit expansion
// ---------------------------------------------------------------------
// Every RVC instruction is defined as a 1:1 expansion of a base RV32I
// instruction, so a core can support the C extension without touching its
// decoder, ALU, or control unit at all: expand the halfword combinationally
// in fetch and feed the existing 32-bit datapath. The only datapath-visible
// differences live elsewhere (PC increments of 2, halfword-aligned fetch).
//
// The whole job is bit-unscrambling. RVC packs immediates in an order chosen
// to keep the *register and sign bits* in fixed positions across formats
// (good for hardware), which makes each immediate a small permutation:
//
//   quadrant 0 (op=00): stack-pointer & register loads/stores
//   quadrant 1 (op=01): immediates, control flow, register-register arith
//   quadrant 2 (op=10): stack-relative loads/stores, jr/jalr/mv/add
//
// 3-bit register fields (rd'/rs1'/rs2') address x8..x15 -- the registers the
// ABI uses most -- which is how 16 bits manage to be enough.
//
// `illegal` flags the defined-illegal/reserved encodings (all-zero halfword,
// addi4spn with zero immediate, RV64-only ops, shamt[5]=1 on RV32, FP forms
// without the F extension). HINT encodings (e.g. c.lui x0) expand normally.
// =====================================================================
`default_nettype none

module rvc_expand (
    input  wire [15:0] c,          // the compressed halfword
    output reg  [31:0] instr32,    // its 32-bit expansion
    output reg         illegal
);
    wire [1:0] op  = c[1:0];
    wire [2:0] f3  = c[15:13];
    wire [4:0] rd  = c[11:7];               // full register fields
    wire [4:0] rs2 = c[6:2];
    wire [4:0] rdp  = {2'b01, c[4:2]};      // rd'/rs2'  -> x8..x15
    wire [4:0] rs1p = {2'b01, c[9:7]};      // rs1'/rd'  -> x8..x15

    // ---- unscrambled immediates (named after their source format) ----
    wire [11:0] imm_ci   = {{7{c[12]}}, c[6:2]};                          // c.addi/c.li/c.andi
    wire [19:0] imm_lui  = {{15{c[12]}}, c[6:2]};                         // c.lui
    wire [11:0] imm_sp16 = {{3{c[12]}}, c[4:3], c[5], c[2], c[6], 4'b0};  // c.addi16sp (x16)
    wire [11:0] imm_spn  = {2'b00, c[10:7], c[12:11], c[5], c[6], 2'b00}; // c.addi4spn (x4)
    wire [11:0] imm_lsw  = {5'b0, c[5], c[12:10], c[6], 2'b00};           // c.lw/c.sw (x4)
    wire [11:0] imm_lwsp = {4'b0, c[3:2], c[12], c[6:4], 2'b00};          // c.lwsp (x4)
    wire [11:0] imm_swsp = {4'b0, c[8:7], c[12:9], 2'b00};                // c.swsp (x4)

    // CJ format -> jal's instr[31:12] field, already in jal's funny order
    // (imm[20|10:1|11|19:12]); the CJ offset bits land as below.
    wire [19:0] jal_f = { c[12],                                          // imm[20]
                          c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3], // imm[10:1]
                          c[12],                                          // imm[11]
                          {8{c[12]}} };                                   // imm[19:12]

    always @(*) begin
        instr32 = 32'h0000_0013;             // default: nop (overwritten below)
        illegal = 1'b0;
        case (op)
        // ---------------- quadrant 0 ----------------
        2'b00: case (f3)
            3'b000: begin                                                  // c.addi4spn
                instr32 = {imm_spn, 5'd2, 3'b000, rdp, 7'b0010011};
                illegal = (imm_spn == 12'd0);          // covers 0x0000 too
            end
            3'b010: instr32 = {imm_lsw, rs1p, 3'b010, rdp, 7'b0000011};    // c.lw
            3'b110: instr32 = {imm_lsw[11:5], rdp, rs1p, 3'b010,
                               imm_lsw[4:0], 7'b0100011};                  // c.sw
            default: illegal = 1'b1;        // c.fld/c.flw/c.fsd/c.fsw: no F/D
        endcase
        // ---------------- quadrant 1 ----------------
        2'b01: case (f3)
            3'b000: instr32 = {imm_ci, rd, 3'b000, rd, 7'b0010011};        // c.addi / c.nop
            3'b001: instr32 = {jal_f, 5'd1, 7'b1101111};                   // c.jal (RV32)
            3'b010: instr32 = {imm_ci, 5'd0, 3'b000, rd, 7'b0010011};      // c.li
            3'b011: begin
                if (rd == 5'd2)
                    instr32 = {imm_sp16, 5'd2, 3'b000, 5'd2, 7'b0010011};  // c.addi16sp
                else
                    instr32 = {imm_lui, rd, 7'b0110111};                   // c.lui
                illegal = ({c[12], c[6:2]} == 6'd0);   // nzimm must be nonzero
            end
            3'b100: case (c[11:10])
                2'b00: begin                                               // c.srli
                    instr32 = {7'b0000000, rs2, rs1p, 3'b101, rs1p, 7'b0010011};
                    illegal = c[12];                   // shamt[5]: RV64 only
                end
                2'b01: begin                                               // c.srai
                    instr32 = {7'b0100000, rs2, rs1p, 3'b101, rs1p, 7'b0010011};
                    illegal = c[12];
                end
                2'b10: instr32 = {imm_ci, rs1p, 3'b111, rs1p, 7'b0010011}; // c.andi
                2'b11: begin
                    case (c[6:5])
                        2'b00: instr32 = {7'b0100000, rdp, rs1p, 3'b000, rs1p, 7'b0110011}; // c.sub
                        2'b01: instr32 = {7'b0000000, rdp, rs1p, 3'b100, rs1p, 7'b0110011}; // c.xor
                        2'b10: instr32 = {7'b0000000, rdp, rs1p, 3'b110, rs1p, 7'b0110011}; // c.or
                        2'b11: instr32 = {7'b0000000, rdp, rs1p, 3'b111, rs1p, 7'b0110011}; // c.and
                    endcase
                    illegal = c[12];                   // c.subw/c.addw: RV64 only
                end
            endcase
            3'b101: instr32 = {jal_f, 5'd0, 7'b1101111};                   // c.j
            3'b110: instr32 = {c[12], {3{c[12]}}, c[6:5], c[2], 5'd0, rs1p,
                               3'b000, c[11:10], c[4:3], c[12], 7'b1100011}; // c.beqz
            3'b111: instr32 = {c[12], {3{c[12]}}, c[6:5], c[2], 5'd0, rs1p,
                               3'b001, c[11:10], c[4:3], c[12], 7'b1100011}; // c.bnez
        endcase
        // ---------------- quadrant 2 ----------------
        2'b10: case (f3)
            3'b000: begin                                                  // c.slli
                instr32 = {7'b0000000, rs2, rd, 3'b001, rd, 7'b0010011};
                illegal = c[12];
            end
            3'b010: begin                                                  // c.lwsp
                instr32 = {imm_lwsp, 5'd2, 3'b010, rd, 7'b0000011};
                illegal = (rd == 5'd0);                // reserved
            end
            3'b100: begin
                if (!c[12]) begin
                    if (rs2 == 5'd0) begin                                 // c.jr
                        instr32 = {12'd0, rd, 3'b000, 5'd0, 7'b1100111};
                        illegal = (rd == 5'd0);        // reserved
                    end else
                        instr32 = {7'b0000000, rs2, 5'd0, 3'b000, rd, 7'b0110011}; // c.mv
                end else begin
                    if (rs2 == 5'd0 && rd == 5'd0)
                        instr32 = 32'h0010_0073;                           // c.ebreak
                    else if (rs2 == 5'd0)
                        instr32 = {12'd0, rd, 3'b000, 5'd1, 7'b1100111};   // c.jalr
                    else
                        instr32 = {7'b0000000, rs2, rd, 3'b000, rd, 7'b0110011};   // c.add
                end
            end
            3'b110: instr32 = {imm_swsp[11:5], rs2, 5'd2, 3'b010,
                               imm_swsp[4:0], 7'b0100011};                 // c.swsp
            default: illegal = 1'b1;        // c.fldsp/c.flwsp/c.fsdsp/c.fswsp
        endcase
        // op == 2'b11 is a 32-bit instruction; the fetch unit never sends it here
        default: illegal = 1'b1;
        endcase
    end
endmodule

`default_nettype wire
