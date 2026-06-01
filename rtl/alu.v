// =====================================================================
// alu.v  -  ALU for RV32IM (base integer + multiply/divide)
// ---------------------------------------------------------------------
// Combinational. 5-bit alu_op selects the operation. The multiply and
// divide operations implement the RV32M extension, including its
// defined results for divide-by-zero and signed overflow.
//
// NOTE: multiply/divide are written combinationally (Verilog * / %) for
// clarity. On an FPGA the multiplier maps to DSP blocks; a combinational
// divider is large -- a real core uses a multi-cycle divider. Fine here
// for a teaching/simulation core.
// =====================================================================
`default_nettype none

module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [4:0]  alu_op,
    output reg  [31:0] result,
    output wire        zero
);
    // ---- base integer ops ----
    localparam ALU_ADD =5'd0,  ALU_SUB =5'd1,  ALU_AND =5'd2,  ALU_OR  =5'd3,
               ALU_XOR =5'd4,  ALU_SLL =5'd5,  ALU_SRL =5'd6,  ALU_SRA =5'd7,
               ALU_SLT =5'd8,  ALU_SLTU=5'd9;
    // ---- RV32M ops ----
    localparam ALU_MUL   =5'd10, ALU_MULH =5'd11, ALU_MULHSU=5'd12,
               ALU_MULHU =5'd13, ALU_DIV  =5'd14, ALU_DIVU  =5'd15,
               ALU_REM   =5'd16, ALU_REMU =5'd17;

    wire [4:0] shamt = b[4:0];

    // 64-bit products for the high-multiply variants.
    wire signed [63:0] a_s  = $signed({{32{a[31]}}, a});   // a as signed64
    wire signed [63:0] b_s  = $signed({{32{b[31]}}, b});   // b as signed64
    wire        [63:0] a_u  = {32'b0, a};                  // a as unsigned64
    wire        [63:0] b_u  = {32'b0, b};                  // b as unsigned64
    wire signed [63:0] p_ss = a_s * b_s;                   // signed   x signed
    wire        [63:0] p_uu = a_u * b_u;                   // unsigned x unsigned
    wire signed [63:0] p_su = a_s * $signed(b_u);          // signed   x unsigned

    // Division with RV32M special cases.
    wire        div0   = (b == 32'd0);
    wire        ovf    = (a == 32'h8000_0000) && (b == 32'hFFFF_FFFF);
    wire signed [31:0] sa = $signed(a);
    wire signed [31:0] sb = $signed(b);
    // Evaluate signed divide/remainder in their own signed context. If
    // mixed with unsigned operands inside a ?: below, Verilog would treat
    // the whole expression as unsigned -- so compute them here first.
    wire signed [31:0] q_s = sa / sb;
    wire signed [31:0] r_s = sa % sb;

    always @(*) begin
        case (alu_op)
            ALU_ADD : result = a + b;
            ALU_SUB : result = a - b;
            ALU_AND : result = a & b;
            ALU_OR  : result = a | b;
            ALU_XOR : result = a ^ b;
            ALU_SLL : result = a << shamt;
            ALU_SRL : result = a >> shamt;
            ALU_SRA : result = $signed(a) >>> shamt;
            ALU_SLT : result = ($signed(a) <  $signed(b)) ? 32'd1 : 32'd0;
            ALU_SLTU: result = (a < b) ? 32'd1 : 32'd0;

            ALU_MUL   : result = p_ss[31:0];      // low 32 (same for all signs)
            ALU_MULH  : result = p_ss[63:32];
            ALU_MULHSU: result = p_su[63:32];
            ALU_MULHU : result = p_uu[63:32];

            ALU_DIV : result = div0 ? 32'hFFFF_FFFF
                              : ovf  ? 32'h8000_0000
                              : q_s;
            ALU_DIVU: result = div0 ? 32'hFFFF_FFFF : (a / b);
            ALU_REM : result = div0 ? a
                              : ovf  ? 32'd0
                              : r_s;
            ALU_REMU: result = div0 ? a : (a % b);

            default : result = 32'd0;
        endcase
    end

    assign zero = (result == 32'd0);
endmodule

`default_nettype wire
