// =====================================================================
// immgen_tb.v  -  Self-checking testbench for the immediate generator
// Uses real, hand-encoded RV32I instructions.
// =====================================================================
`timescale 1ns/1ps
`default_nettype none

module immgen_tb;
    reg  [31:0] instr;
    reg  [2:0]  imm_type;
    wire [31:0] imm;
    integer errors = 0;

    immgen dut (.instr(instr), .imm_type(imm_type), .imm(imm));

    localparam IMM_I=3'b000, IMM_S=3'b001, IMM_B=3'b010,
               IMM_U=3'b011, IMM_J=3'b100;

    task check;
        input [31:0] i;
        input [2:0]  t;
        input [31:0] expected;
        begin
            instr = i; imm_type = t; #1;
            if (imm !== expected) begin
                $display("FAIL instr=%h type=%b -> got %h, expected %h",
                         i, t, imm, expected);
                errors = errors + 1;
            end else
                $display("ok   instr=%h type=%b -> %h", i, t, imm);
        end
    endtask

    initial begin
        $dumpfile("build/immgen_tb.vcd");
        $dumpvars(0, immgen_tb);

        // addi x1, x0, -1   (imm = -1, sign-extended)
        check(32'hFFF00093, IMM_I, 32'hFFFFFFFF);
        // addi x1, x0, 5
        check(32'h00500093, IMM_I, 32'h00000005);
        // lui  x1, 0xABCDE  -> imm = 0xABCDE000
        check(32'hABCDE0B7, IMM_U, 32'hABCDE000);
        // beq  x0, x0, +8   -> imm = 8
        check(32'h00000463, IMM_B, 32'h00000008);
        // jal  x1, +0x800   -> imm = 0x800
        check(32'h001000EF, IMM_J, 32'h00000800);
        // S-type store with all immediate bits set:
        //   instr[31:25]=1111111, instr[11:7]=11111  ->  imm = -1
        check(32'hFE000FA3, IMM_S, 32'hFFFFFFFF);

        $display("--------------------------------------------------");
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d TEST(S) FAILED", errors);
        $finish;
    end
endmodule

`default_nettype wire
