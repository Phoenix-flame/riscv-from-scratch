// =====================================================================
// c_tb.v  -  Run the compiled C program (cprog.hex) on the CPU.
// Expects main() -> 55, stored by crt0 at data memory address 0.
// =====================================================================
`timescale 1ns/1ps
`default_nettype none

module c_tb;
    reg clk, rst;
    wire [31:0] pc, instr;
    integer errors = 0, c;

    cpu #(.INIT_FILE("sw/cprog.hex")) dut (
        .clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    wire [31:0] result = {dut.u_dmem.mem[3], dut.u_dmem.mem[2],
                          dut.u_dmem.mem[1], dut.u_dmem.mem[0]};

    initial begin
        $dumpfile("build/c_tb.vcd");
        $dumpvars(0, c_tb);

        rst = 1; @(posedge clk); #1; rst = 0;

        // Run until the program reaches its halt self-loop.
        for (c = 0; c < 80; c = c + 1) @(posedge clk);
        #1;

        $display("a0/return value stored at mem[0] = %0d", result);
        $display("final pc = %h (should sit at the halt loop)", pc);

        if (result !== 32'd55) begin
            $display("FAIL: got %0d, expected 55", result);
            errors = errors + 1;
        end

        if (errors == 0) $display("ALL TESTS PASSED  (C program returned 55)");
        else             $display("%0d TEST(S) FAILED", errors);
        $finish;
    end
endmodule

`default_nettype wire
