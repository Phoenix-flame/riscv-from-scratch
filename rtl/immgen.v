// =====================================================================
// immgen.v  -  Immediate generator for RV32I
// ---------------------------------------------------------------------
// RV32I scatters the bits of an immediate across the instruction word so
// that the register fields stay in fixed positions. This block puts them
// back together into a clean, sign-extended 32-bit constant, choosing the
// layout based on `imm_type` (supplied by the control unit).
//
// Reference layouts (bit positions within the 32-bit instruction):
//   I : imm[11:0]  = instr[31:20]
//   S : imm[11:0]  = {instr[31:25], instr[11:7]}
//   B : imm[12:0]  = {instr[31], instr[7], instr[30:25], instr[11:8], 0}
//   U : imm[31:12] = instr[31:12]   (low 12 bits are zero)
//   J : imm[20:0]  = {instr[31], instr[19:12], instr[20], instr[30:21], 0}
// All except U are sign-extended from their top bit.
// =====================================================================
`default_nettype none

module immgen (
    input  wire [31:0] instr,
    input  wire [2:0]  imm_type,
    output reg  [31:0] imm
);
    localparam IMM_I = 3'b000;
    localparam IMM_S = 3'b001;
    localparam IMM_B = 3'b010;
    localparam IMM_U = 3'b011;
    localparam IMM_J = 3'b100;

    always @(*) begin
        case (imm_type)
            IMM_I: imm = {{20{instr[31]}}, instr[31:20]};
            IMM_S: imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
            IMM_B: imm = {{19{instr[31]}}, instr[31], instr[7],
                          instr[30:25], instr[11:8], 1'b0};
            IMM_U: imm = {instr[31:12], 12'b0};
            IMM_J: imm = {{11{instr[31]}}, instr[31], instr[19:12],
                          instr[20], instr[30:21], 1'b0};
            default: imm = 32'd0;
        endcase
    end
endmodule

`default_nettype wire
