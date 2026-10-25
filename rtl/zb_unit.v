// =====================================================================
// zb_unit.v  -  the bit-manipulation extensions: Zba, Zbb, Zbc, Zbs
// ---------------------------------------------------------------------
// Step 46. A combinational unit beside the ALU. It recognises every RV32
// Zba/Zbb/Zbc/Zbs encoding (OP and OP-IMM opcodes, distinguished from the
// base and M instructions by funct7 / the immediate's top bits) and
// computes the result; the pipeline uses that instead of the ALU's when
// `hit` is set. Each group can be left out (ZBA..ZBS = 0): its encodings
// then do not hit -- and the core decodes them as illegal.
//
//   Zba  sh1add sh2add sh3add                         address generation
//   Zbb  andn orn xnor  clz ctz cpop  min[u] max[u]
//        sext.b sext.h zext.h  rol ror rori  orc.b rev8    basic bit-manip
//   Zbc  clmul clmulh clmulr                          carry-less multiply
//   Zbs  bclr[i] bset[i] binv[i] bext[i]              single-bit ops
// =====================================================================
`default_nettype none

module zb_unit #(
    parameter ZBA = 1,
    parameter ZBB = 1,
    parameter ZBC = 1,
    parameter ZBS = 1
) (
    input  wire [6:0]  opcode,
    input  wire [2:0]  funct3,
    input  wire [6:0]  funct7,        // instr[31:25]
    input  wire [4:0]  rs2f,          // instr[24:20] (selects unary ops)
    input  wire [31:0] a,             // rs1
    input  wire [31:0] b,             // rs2, or the immediate (shamt in [4:0])
    output reg         hit,
    output reg  [31:0] result
);
    wire op_r = (opcode == 7'b0110011);
    wire op_i = (opcode == 7'b0010011);
    wire [4:0] sh = b[4:0];

    // ---- helpers ----
    function [5:0] clz32; input [31:0] x; integer k; reg done;
        begin clz32 = 32; done = 0;
            for (k = 31; k >= 0; k = k - 1) if (!done && x[k]) begin clz32 = 31 - k; done = 1; end
        end
    endfunction
    function [5:0] ctz32; input [31:0] x; integer k; reg done;
        begin ctz32 = 32; done = 0;
            for (k = 0; k < 32; k = k + 1) if (!done && x[k]) begin ctz32 = k; done = 1; end
        end
    endfunction
    function [5:0] cpop32; input [31:0] x; integer k;
        begin cpop32 = 0; for (k = 0; k < 32; k = k + 1) cpop32 = cpop32 + x[k]; end
    endfunction
    // carry-less product of a and b, all 64 bits
    function [63:0] clmul64; input [31:0] x, y; integer k;
        begin clmul64 = 64'd0;
            for (k = 0; k < 32; k = k + 1) if (y[k]) clmul64 = clmul64 ^ ({32'd0, x} << k);
        end
    endfunction

    wire [63:0] cl   = (ZBC != 0) ? clmul64(a, b) : 64'd0;
    wire [31:0] rol_ = (a << sh) | (a >> (6'd32 - {1'b0, sh}));
    wire [31:0] ror_ = (a >> sh) | (a << (6'd32 - {1'b0, sh}));
    wire [31:0] onehot = 32'd1 << sh;

    always @(*) begin
        hit = 1'b0; result = 32'd0;
        if (op_r) case (funct7)
            7'b0100000: if (ZBB) case (funct3)                     // andn / orn / xnor
                3'b111: begin hit = 1; result = a & ~b; end
                3'b110: begin hit = 1; result = a | ~b; end
                3'b100: begin hit = 1; result = ~(a ^ b); end
                default: ;
            endcase
            7'b0000101: case (funct3)
                3'b100: if (ZBB) begin hit = 1; result = ($signed(a) < $signed(b)) ? a : b; end   // min
                3'b101: if (ZBB) begin hit = 1; result = (a < b) ? a : b; end                     // minu
                3'b110: if (ZBB) begin hit = 1; result = ($signed(a) < $signed(b)) ? b : a; end   // max
                3'b111: if (ZBB) begin hit = 1; result = (a < b) ? b : a; end                     // maxu
                3'b001: if (ZBC) begin hit = 1; result = cl[31:0];  end                           // clmul
                3'b011: if (ZBC) begin hit = 1; result = cl[63:32]; end                           // clmulh
                3'b010: if (ZBC) begin hit = 1; result = cl[62:31]; end                           // clmulr
                default: ;
            endcase
            7'b0110000: if (ZBB) case (funct3)
                3'b001: begin hit = 1; result = rol_; end
                3'b101: begin hit = 1; result = ror_; end
                default: ;
            endcase
            7'b0010000: if (ZBA) case (funct3)
                3'b010: begin hit = 1; result = (a << 1) + b; end
                3'b100: begin hit = 1; result = (a << 2) + b; end
                3'b110: begin hit = 1; result = (a << 3) + b; end
                default: ;
            endcase
            7'b0000100: if (ZBB && funct3 == 3'b100 && rs2f == 5'd0) begin   // zext.h
                hit = 1; result = {16'd0, a[15:0]}; end
            7'b0100100: if (ZBS) case (funct3)
                3'b001: begin hit = 1; result = a & ~onehot; end                 // bclr
                3'b101: begin hit = 1; result = {31'd0, |(a & onehot)}; end      // bext
                default: ;
            endcase
            7'b0010100: if (ZBS && funct3 == 3'b001) begin hit = 1; result = a | onehot; end  // bset
            7'b0110100: if (ZBS && funct3 == 3'b001) begin hit = 1; result = a ^ onehot; end  // binv
            default: ;
        endcase
        else if (op_i) case (funct3)
            3'b001: case (funct7)
                7'b0110000: if (ZBB) case (rs2f)
                    5'd0: begin hit = 1; result = {26'd0, clz32(a)};  end
                    5'd1: begin hit = 1; result = {26'd0, ctz32(a)};  end
                    5'd2: begin hit = 1; result = {26'd0, cpop32(a)}; end
                    5'd4: begin hit = 1; result = {{24{a[7]}},  a[7:0]};  end   // sext.b
                    5'd5: begin hit = 1; result = {{16{a[15]}}, a[15:0]}; end   // sext.h
                    default: ;
                endcase
                7'b0100100: if (ZBS) begin hit = 1; result = a & ~onehot; end   // bclri
                7'b0010100: if (ZBS) begin hit = 1; result = a | onehot;  end   // bseti
                7'b0110100: if (ZBS) begin hit = 1; result = a ^ onehot;  end   // binvi
                default: ;
            endcase
            3'b101: case (funct7)
                7'b0110000: if (ZBB) begin hit = 1; result = ror_; end          // rori
                7'b0100100: if (ZBS) begin hit = 1; result = {31'd0, |(a & onehot)}; end  // bexti
                7'b0010100: if (ZBB && rs2f == 5'b00111) begin                  // orc.b
                    hit = 1;
                    result = {{8{|a[31:24]}}, {8{|a[23:16]}}, {8{|a[15:8]}}, {8{|a[7:0]}}};
                end
                7'b0110100: if (ZBB && rs2f == 5'b11000) begin                  // rev8
                    hit = 1; result = {a[7:0], a[15:8], a[23:16], a[31:24]};
                end
                default: ;
            endcase
            default: ;
        endcase
    end
endmodule

`default_nettype wire
