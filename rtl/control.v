// =====================================================================
// control.v  -  Main control unit for the single-cycle RV32I core
// ---------------------------------------------------------------------
// Pure combinational decode. From the opcode (plus funct3 and one bit of
// funct7) it produces every control signal the datapath needs to steer
// the right data through the right path for one instruction.
// =====================================================================
`default_nettype none

module control (
    input  wire [6:0] opcode,
    input  wire [2:0] funct3,
    input  wire       funct7b5,    // instr[30]: add/sub, srl/sra selector

    output reg        reg_write,   // write the result into rd
    output reg        alu_src_a,   // ALU operand A: 0=rs1, 1=PC  (auipc)
    output reg        alu_src_b,   // ALU operand B: 0=rs2, 1=imm
    output reg        mem_read,    // this is a load
    output reg        mem_write,   // this is a store
    output reg        branch,      // this is a conditional branch
    output reg        jump,        // this is jal or jalr
    output reg        jalr,        // distinguishes jalr (target = rs1+imm)
    output reg [1:0]  wb_sel,      // what gets written back (see below)
    output reg [2:0]  imm_type,    // which immediate layout to build
    output reg [3:0]  alu_op       // ALU operation code (Step 03)
);
    // ---- Opcodes ----------------------------------------------------
    localparam OP_R     = 7'b0110011;  // add, sub, and, or, ...
    localparam OP_I     = 7'b0010011;  // addi, andi, slli, ...
    localparam OP_LOAD  = 7'b0000011;  // lb, lh, lw, lbu, lhu
    localparam OP_STORE = 7'b0100011;  // sb, sh, sw
    localparam OP_BR    = 7'b1100011;  // beq, bne, blt, ...
    localparam OP_JAL   = 7'b1101111;
    localparam OP_JALR  = 7'b1100111;
    localparam OP_LUI   = 7'b0110111;
    localparam OP_AUIPC = 7'b0010111;

    // ---- Immediate types (must match immgen.v) ----------------------
    localparam IMM_I=3'b000, IMM_S=3'b001, IMM_B=3'b010,
               IMM_U=3'b011, IMM_J=3'b100;

    // ---- Write-back source ------------------------------------------
    localparam WB_ALU=2'b00, WB_MEM=2'b01, WB_PC4=2'b10, WB_IMM=2'b11;

    // ---- ALU op codes (must match alu.v) ----------------------------
    localparam ALU_ADD=4'b0000, ALU_SUB=4'b0001, ALU_AND=4'b0010,
               ALU_OR =4'b0011, ALU_XOR=4'b0100, ALU_SLL=4'b0101,
               ALU_SRL=4'b0110, ALU_SRA=4'b0111, ALU_SLT=4'b1000,
               ALU_SLTU=4'b1001;

    // Decode funct3/funct7 into an ALU op. `is_imm` is 1 for I-type ALU
    // ops, where funct3==000 is always ADD (addi never subtracts).
    function [3:0] alu_decode;
        input [2:0] f3;
        input       f7b5;
        input       is_imm;
        begin
            case (f3)
                3'b000: alu_decode = is_imm ? ALU_ADD
                                            : (f7b5 ? ALU_SUB : ALU_ADD);
                3'b001: alu_decode = ALU_SLL;
                3'b010: alu_decode = ALU_SLT;
                3'b011: alu_decode = ALU_SLTU;
                3'b100: alu_decode = ALU_XOR;
                3'b101: alu_decode = f7b5 ? ALU_SRA : ALU_SRL;
                3'b110: alu_decode = ALU_OR;
                3'b111: alu_decode = ALU_AND;
                default: alu_decode = ALU_ADD;
            endcase
        end
    endfunction

    always @(*) begin
        // Safe defaults: do nothing. Every signal is assigned here, so no
        // latch can be inferred and an unknown opcode is a harmless NOP.
        reg_write = 1'b0;
        alu_src_a = 1'b0;
        alu_src_b = 1'b0;
        mem_read  = 1'b0;
        mem_write = 1'b0;
        branch    = 1'b0;
        jump      = 1'b0;
        jalr      = 1'b0;
        wb_sel    = WB_ALU;
        imm_type  = IMM_I;
        alu_op    = ALU_ADD;

        case (opcode)
            OP_R: begin
                reg_write = 1'b1;
                alu_op    = alu_decode(funct3, funct7b5, 1'b0);
            end
            OP_I: begin
                reg_write = 1'b1;
                alu_src_b = 1'b1;
                imm_type  = IMM_I;
                alu_op    = alu_decode(funct3, funct7b5, 1'b1);
            end
            OP_LOAD: begin
                reg_write = 1'b1;
                alu_src_b = 1'b1;        // address = rs1 + imm
                imm_type  = IMM_I;
                mem_read  = 1'b1;
                wb_sel    = WB_MEM;
                alu_op    = ALU_ADD;
            end
            OP_STORE: begin
                alu_src_b = 1'b1;        // address = rs1 + imm
                imm_type  = IMM_S;
                mem_write = 1'b1;
                alu_op    = ALU_ADD;
            end
            OP_BR: begin
                branch    = 1'b1;
                imm_type  = IMM_B;
                alu_op    = ALU_SUB;     // datapath uses compare + funct3
            end
            OP_JAL: begin
                reg_write = 1'b1;
                jump      = 1'b1;
                imm_type  = IMM_J;
                wb_sel    = WB_PC4;      // rd = return address (PC+4)
            end
            OP_JALR: begin
                reg_write = 1'b1;
                jump      = 1'b1;
                jalr      = 1'b1;
                alu_src_b = 1'b1;
                imm_type  = IMM_I;
                wb_sel    = WB_PC4;
            end
            OP_LUI: begin
                reg_write = 1'b1;
                imm_type  = IMM_U;
                wb_sel    = WB_IMM;      // rd = imm
            end
            OP_AUIPC: begin
                reg_write = 1'b1;
                alu_src_a = 1'b1;        // operand A = PC
                alu_src_b = 1'b1;        // operand B = imm
                imm_type  = IMM_U;
                alu_op    = ALU_ADD;     // rd = PC + imm
                wb_sel    = WB_ALU;
            end
            default: ; // illegal/unknown: keep defaults (NOP)
        endcase
    end
endmodule

`default_nettype wire
