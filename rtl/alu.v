// =====================================================================
// alu.v  -  Arithmetic Logic Unit for an RV32I core
// ---------------------------------------------------------------------
// Pure combinational block. Given two 32-bit operands and a 4-bit
// operation selector, it produces a 32-bit result and a `zero` flag
// (used later by branch instructions).
// =====================================================================
`default_nettype none

module alu (
    input  wire [31:0] a,        // operand A
    input  wire [31:0] b,        // operand B
    input  wire [3:0]  alu_op,   // operation selector
    output reg  [31:0] result,   // ALU output
    output wire        zero      // 1 when result == 0
);

    // ---- Operation encodings (we choose these; the control unit
    //      built in a later step will emit them) -----------------------
    localparam ALU_ADD  = 4'b0000;
    localparam ALU_SUB  = 4'b0001;
    localparam ALU_AND  = 4'b0010;
    localparam ALU_OR   = 4'b0011;
    localparam ALU_XOR  = 4'b0100;
    localparam ALU_SLL  = 4'b0101;  // shift left logical
    localparam ALU_SRL  = 4'b0110;  // shift right logical
    localparam ALU_SRA  = 4'b0111;  // shift right arithmetic
    localparam ALU_SLT  = 4'b1000;  // set less than (signed)
    localparam ALU_SLTU = 4'b1001;  // set less than (unsigned)

    // Only the low 5 bits of B are used as a shift amount in RV32I.
    wire [4:0] shamt = b[4:0];

    always @(*) begin
        case (alu_op)
            ALU_ADD : result = a + b;
            ALU_SUB : result = a - b;
            ALU_AND : result = a & b;
            ALU_OR  : result = a | b;
            ALU_XOR : result = a ^ b;
            ALU_SLL : result = a << shamt;
            ALU_SRL : result = a >> shamt;
            // $signed() makes >> do an arithmetic (sign-extending) shift
            ALU_SRA : result = $signed(a) >>> shamt;
            // signed compare: cast both operands
            ALU_SLT : result = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
            // unsigned compare: raw values
            ALU_SLTU: result = (a < b) ? 32'd1 : 32'd0;
            default : result = 32'd0;
        endcase
    end

    assign zero = (result == 32'd0);

endmodule

`default_nettype wire
