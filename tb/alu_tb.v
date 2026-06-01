`timescale 1ns/1ps
`default_nettype none
module alu_tb;
    reg  [31:0] a, b;
    reg  [4:0]  alu_op;
    wire [31:0] result;
    wire        zero;
    integer errors = 0;

    alu dut (.a(a), .b(b), .alu_op(alu_op), .result(result), .zero(zero));

    localparam ADD=5'd0,SUB=5'd1,AND=5'd2,OR=5'd3,XOR=5'd4,SLL=5'd5,
               SRL=5'd6,SRA=5'd7,SLT=5'd8,SLTU=5'd9,
               MUL=5'd10,MULH=5'd11,MULHSU=5'd12,MULHU=5'd13,
               DIV=5'd14,DIVU=5'd15,REM=5'd16,REMU=5'd17;

    task check;
        input [4:0]  op; input [31:0] ia, ib, expected;
        begin
            a=ia; b=ib; alu_op=op; #1;
            if (result !== expected) begin
                $display("FAIL op=%0d a=%h b=%h -> got %h, expected %h",
                         op, ia, ib, result, expected);
                errors=errors+1;
            end else $display("ok   op=%0d a=%h b=%h -> %h", op, ia, ib, result);
        end
    endtask

    initial begin
        $dumpfile("build/alu_tb.vcd"); $dumpvars(0, alu_tb);
        // base integer
        check(ADD, 32'd5, 32'd7, 32'd12);
        check(SUB, 32'd3, 32'd10, -32'sd7);
        check(SRA, 32'h80000000, 32'd4, 32'hF8000000);
        check(SLT, -32'sd5, 32'd3, 32'd1);
        check(SLTU,32'hFFFFFFFF, 32'd1, 32'd0);
        // RV32M: multiply
        check(MUL,  32'd6, 32'd7, 32'd42);
        check(MUL,  -32'sd6, 32'd7, -32'sd42);          // low 32 bits
        check(MULH, 32'h40000000, 32'd4, 32'd1);        // (2^30*4)>>32 = 1
        check(MULHU,32'hFFFFFFFF, 32'hFFFFFFFF, 32'hFFFFFFFE);
        check(MULHSU,32'hFFFFFFFF, 32'd2, 32'hFFFFFFFF); // -1 * 2 -> high = -1
        // RV32M: divide / remainder
        check(DIV,  32'd20, 32'd6, 32'd3);
        check(REM,  32'd20, 32'd6, 32'd2);
        check(DIV,  -32'sd20, 32'd6, -32'sd3);          // trunc toward zero
        check(REM,  -32'sd20, 32'd6, -32'sd2);
        check(DIVU, 32'd20, 32'd6, 32'd3);
        check(REMU, 32'd20, 32'd6, 32'd2);
        // RV32M edge cases
        check(DIV,  32'd7, 32'd0, 32'hFFFFFFFF);        // div by zero -> -1
        check(REM,  32'd7, 32'd0, 32'd7);               // rem by zero -> a
        check(DIVU, 32'd7, 32'd0, 32'hFFFFFFFF);
        check(DIV,  32'h80000000, 32'hFFFFFFFF, 32'h80000000); // overflow
        check(REM,  32'h80000000, 32'hFFFFFFFF, 32'd0);

        $display("--------------------------------------------------");
        if (errors==0) $display("ALL TESTS PASSED");
        else           $display("%0d TEST(S) FAILED", errors);
        $finish;
    end
endmodule
`default_nettype wire
