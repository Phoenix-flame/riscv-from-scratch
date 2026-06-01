`timescale 1ns/1ps
`default_nettype none
module control_tb;
    reg  [6:0] opcode;
    reg  [2:0] funct3;
    reg  [6:0] funct7;
    wire       reg_write, alu_src_a, alu_src_b, mem_read, mem_write;
    wire       branch, jump, jalr;
    wire [1:0] wb_sel;
    wire [2:0] imm_type;
    wire [4:0] alu_op;
    integer errors = 0;

    control dut (.opcode(opcode), .funct3(funct3), .funct7(funct7),
        .reg_write(reg_write), .alu_src_a(alu_src_a), .alu_src_b(alu_src_b),
        .mem_read(mem_read), .mem_write(mem_write), .branch(branch),
        .jump(jump), .jalr(jalr), .wb_sel(wb_sel), .imm_type(imm_type),
        .alu_op(alu_op));

    localparam OP_R=7'b0110011, OP_I=7'b0010011, OP_LOAD=7'b0000011,
               OP_STORE=7'b0100011, OP_BR=7'b1100011, OP_JAL=7'b1101111,
               OP_JALR=7'b1100111, OP_LUI=7'b0110111, OP_AUIPC=7'b0010111;
    localparam WB_ALU=2'b00, WB_MEM=2'b01, WB_PC4=2'b10, WB_IMM=2'b11;
    localparam IMM_I=3'b000,IMM_S=3'b001,IMM_B=3'b010,IMM_U=3'b011,IMM_J=3'b100;
    localparam A_ADD=5'd0,A_SUB=5'd1,A_SLT=5'd8,A_SLL=5'd5,A_SRA=5'd7,
               A_MUL=5'd10,A_DIVU=5'd15;

    task check;
        input [8*8:1] name;
        input [6:0] op; input [2:0] f3; input [6:0] f7;
        input e_rw,e_asa,e_asb,e_mr,e_mw,e_br,e_jmp,e_jalr;
        input [1:0] e_wb; input [2:0] e_imm; input [4:0] e_alu;
        reg ok;
        begin
            opcode=op; funct3=f3; funct7=f7; #1;
            ok = (reg_write===e_rw)&&(alu_src_a===e_asa)&&(alu_src_b===e_asb)&&
                 (mem_read===e_mr)&&(mem_write===e_mw)&&(branch===e_br)&&
                 (jump===e_jmp)&&(jalr===e_jalr)&&(wb_sel===e_wb)&&
                 (imm_type===e_imm)&&(alu_op===e_alu);
            if(!ok) begin
                $display("FAIL %0s: rw=%b asb=%b mr=%b mw=%b br=%b jmp=%b wb=%b imm=%b alu=%0d",
                    name,reg_write,alu_src_b,mem_read,mem_write,branch,jump,wb_sel,imm_type,alu_op);
                errors=errors+1;
            end else $display("ok   %0s", name);
        end
    endtask

    initial begin
        $dumpfile("build/control_tb.vcd"); $dumpvars(0, control_tb);
        //    name      op        f3      f7          rw asa asb mr mw br jmp jalr wb     imm    alu
        check("add", OP_R,    3'b000, 7'b0000000, 1,0,0,0,0,0,0,0, WB_ALU,IMM_I,A_ADD);
        check("sub", OP_R,    3'b000, 7'b0100000, 1,0,0,0,0,0,0,0, WB_ALU,IMM_I,A_SUB);
        check("slt", OP_R,    3'b010, 7'b0000000, 1,0,0,0,0,0,0,0, WB_ALU,IMM_I,A_SLT);
        check("mul", OP_R,    3'b000, 7'b0000001, 1,0,0,0,0,0,0,0, WB_ALU,IMM_I,A_MUL);
        check("divu",OP_R,    3'b101, 7'b0000001, 1,0,0,0,0,0,0,0, WB_ALU,IMM_I,A_DIVU);
        check("addi",OP_I,    3'b000, 7'b0100000, 1,0,1,0,0,0,0,0, WB_ALU,IMM_I,A_ADD);
        check("slli",OP_I,    3'b001, 7'b0000000, 1,0,1,0,0,0,0,0, WB_ALU,IMM_I,A_SLL);
        check("lw",  OP_LOAD, 3'b010, 7'b0000000, 1,0,1,1,0,0,0,0, WB_MEM,IMM_I,A_ADD);
        check("sw",  OP_STORE,3'b010, 7'b0000000, 0,0,1,0,1,0,0,0, WB_ALU,IMM_S,A_ADD);
        check("beq", OP_BR,   3'b000, 7'b0000000, 0,0,0,0,0,1,0,0, WB_ALU,IMM_B,A_SUB);
        check("jal", OP_JAL,  3'b000, 7'b0000000, 1,0,0,0,0,0,1,0, WB_PC4,IMM_J,A_ADD);
        check("lui", OP_LUI,  3'b000, 7'b0000000, 1,0,0,0,0,0,0,0, WB_IMM,IMM_U,A_ADD);
        check("illegal",7'b1111111,3'b000,7'b0,   0,0,0,0,0,0,0,0, WB_ALU,IMM_I,A_ADD);

        $display("--------------------------------------------------");
        if (errors==0) $display("ALL TESTS PASSED");
        else           $display("%0d TEST(S) FAILED", errors);
        $finish;
    end
endmodule
`default_nettype wire
