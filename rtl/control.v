// =====================================================================
// control.v  -  Main control unit for the single-cycle RV32IM core
// ---------------------------------------------------------------------
// Pure combinational decode. Produces the control signals the datapath
// needs. Now decodes the RV32M ops (R-type with funct7 == 0000001) and
// outputs a 5-bit alu_op.
// =====================================================================
`default_nettype none

module control (
    input  wire [6:0] opcode,
    input  wire [2:0] funct3,
    input  wire [6:0] funct7,      // full funct7 (add/sub, sra, and M ext)

    output reg        reg_write,
    output reg        alu_src_a,
    output reg        alu_src_b,
    output reg        mem_read,
    output reg        mem_write,
    output reg        branch,
    output reg        jump,
    output reg        jalr,
    output reg [1:0]  wb_sel,
    output reg [2:0]  imm_type,
    output reg [4:0]  alu_op
);
    localparam OP_R     = 7'b0110011, OP_I    = 7'b0010011,
               OP_LOAD  = 7'b0000011, OP_STORE= 7'b0100011,
               OP_BR    = 7'b1100011, OP_JAL  = 7'b1101111,
               OP_JALR  = 7'b1100111, OP_LUI  = 7'b0110111,
               OP_AUIPC = 7'b0010111, OP_AMO  = 7'b0101111;

    localparam IMM_I=3'b000, IMM_S=3'b001, IMM_B=3'b010, IMM_U=3'b011, IMM_J=3'b100;
    localparam WB_ALU=2'b00, WB_MEM=2'b01, WB_PC4=2'b10, WB_IMM=2'b11;

    // 5-bit ALU op codes (must match alu.v)
    localparam ALU_ADD=5'd0, ALU_SUB=5'd1, ALU_AND=5'd2, ALU_OR=5'd3,
               ALU_XOR=5'd4, ALU_SLL=5'd5, ALU_SRL=5'd6, ALU_SRA=5'd7,
               ALU_SLT=5'd8, ALU_SLTU=5'd9,
               ALU_MUL=5'd10, ALU_MULH=5'd11, ALU_MULHSU=5'd12, ALU_MULHU=5'd13,
               ALU_DIV=5'd14, ALU_DIVU=5'd15, ALU_REM=5'd16, ALU_REMU=5'd17;

    wire is_m = (funct7 == 7'b0000001);   // RV32M marker for R-type
    wire f7b5 = funct7[5];                // add/sub, srl/sra selector

    // base R/I ALU op from funct3 (+ funct7 bit 5). is_imm forces ADD for
    // funct3==000 (addi never subtracts).
    function [4:0] alu_base;
        input [2:0] f3; input b5; input is_imm;
        case (f3)
            3'b000: alu_base = is_imm ? ALU_ADD : (b5 ? ALU_SUB : ALU_ADD);
            3'b001: alu_base = ALU_SLL;
            3'b010: alu_base = ALU_SLT;
            3'b011: alu_base = ALU_SLTU;
            3'b100: alu_base = ALU_XOR;
            3'b101: alu_base = b5 ? ALU_SRA : ALU_SRL;
            3'b110: alu_base = ALU_OR;
            3'b111: alu_base = ALU_AND;
            default:alu_base = ALU_ADD;
        endcase
    endfunction

    // RV32M op from funct3
    function [4:0] alu_muldiv;
        input [2:0] f3;
        case (f3)
            3'b000: alu_muldiv = ALU_MUL;
            3'b001: alu_muldiv = ALU_MULH;
            3'b010: alu_muldiv = ALU_MULHSU;
            3'b011: alu_muldiv = ALU_MULHU;
            3'b100: alu_muldiv = ALU_DIV;
            3'b101: alu_muldiv = ALU_DIVU;
            3'b110: alu_muldiv = ALU_REM;
            3'b111: alu_muldiv = ALU_REMU;
            default:alu_muldiv = ALU_MUL;
        endcase
    endfunction

    always @(*) begin
        reg_write=1'b0; alu_src_a=1'b0; alu_src_b=1'b0;
        mem_read=1'b0;  mem_write=1'b0; branch=1'b0; jump=1'b0; jalr=1'b0;
        wb_sel=WB_ALU;  imm_type=IMM_I; alu_op=ALU_ADD;

        case (opcode)
            OP_R: begin
                reg_write = 1'b1;
                alu_op    = is_m ? alu_muldiv(funct3)
                                 : alu_base(funct3, f7b5, 1'b0);
            end
            OP_I: begin
                reg_write = 1'b1; alu_src_b = 1'b1; imm_type = IMM_I;
                alu_op    = alu_base(funct3, f7b5, 1'b1);
            end
            OP_LOAD: begin
                reg_write=1'b1; alu_src_b=1'b1; imm_type=IMM_I;
                mem_read=1'b1; wb_sel=WB_MEM; alu_op=ALU_ADD;
            end
            OP_STORE: begin
                alu_src_b=1'b1; imm_type=IMM_S; mem_write=1'b1; alu_op=ALU_ADD;
            end
            OP_BR: begin
                branch=1'b1; imm_type=IMM_B; alu_op=ALU_SUB;
            end
            OP_JAL: begin
                reg_write=1'b1; jump=1'b1; imm_type=IMM_J; wb_sel=WB_PC4;
            end
            OP_JALR: begin
                reg_write=1'b1; jump=1'b1; jalr=1'b1; alu_src_b=1'b1;
                imm_type=IMM_I; wb_sel=WB_PC4;
            end
            OP_LUI: begin
                reg_write=1'b1; imm_type=IMM_U; wb_sel=WB_IMM;
            end
            OP_AUIPC: begin
                reg_write=1'b1; alu_src_a=1'b1; alu_src_b=1'b1;
                imm_type=IMM_U; alu_op=ALU_ADD; wb_sel=WB_ALU;
            end
            OP_AMO: begin
                // A-extension (LR/SC/AMO). The core supplies the address
                // (rs1, no immediate), the read-modify-write value, and the
                // store-conditional result; here we just mark it as a
                // register-writing memory op whose rd takes the loaded word.
                reg_write=1'b1; mem_read=1'b1; wb_sel=WB_MEM; alu_op=ALU_ADD;
            end
            default: ;
        endcase
    end
endmodule

`default_nettype wire
