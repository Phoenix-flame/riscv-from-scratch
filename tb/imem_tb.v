// =====================================================================
// imem_tb.v  -  Self-checking testbench for instruction memory
// =====================================================================
`timescale 1ns/1ps
`default_nettype none

module imem_tb;
    reg  [31:0] addr;
    wire [31:0] instr;
    integer errors = 0;

    imem #(.WORDS(256), .INIT_FILE("sw/test_imem.hex")) dut (
        .addr(addr), .instr(instr)
    );

    task check;
        input [31:0] a;
        input [31:0] expected;
        begin
            addr = a; #1;
            if (instr !== expected) begin
                $display("FAIL pc=%h -> got %h, expected %h", a, instr, expected);
                errors = errors + 1;
            end else
                $display("ok   pc=%h -> %h", a, instr);
        end
    endtask

    initial begin
        $dumpfile("build/imem_tb.vcd");
        $dumpvars(0, imem_tb);

        // Word 0,1,2,3 sit at byte addresses 0,4,8,12.
        check(32'h00000000, 32'hdeadbeef);
        check(32'h00000004, 32'h00000013);  // this is a NOP (addi x0,x0,0)
        check(32'h00000008, 32'hcafef00d);
        check(32'h0000000c, 32'h12345678);
        check(32'h00000010, 32'h00000000);  // unloaded -> zero

        $display("--------------------------------------------------");
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d TEST(S) FAILED", errors);
        $finish;
    end
endmodule

`default_nettype wire
