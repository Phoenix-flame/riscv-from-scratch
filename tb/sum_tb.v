// =====================================================================
// sum_tb.v  -  Run the assembled sum.hex on the CPU and verify 1+..+10.
// =====================================================================
`timescale 1ns/1ps
`default_nettype none

module sum_tb;
    reg clk, rst;
    wire [31:0] pc, instr;
    integer errors = 0, c;

    cpu #(.INIT_FILE("sw/sum.hex")) dut (
        .clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    initial begin
        $dumpfile("build/sum_tb.vcd");
        $dumpvars(0, sum_tb);

        rst = 1; @(posedge clk); #1; rst = 0;

        // Run long enough for the loop (10 iterations x ~4 instr + setup).
        for (c = 0; c < 60; c = c + 1) @(posedge clk);
        #1;

        $display("x1 (sum)   = %0d", dut.u_regfile.regs[1]);
        $display("mem[0..3]  = %h %h %h %h",
                 dut.u_dmem.mem[3], dut.u_dmem.mem[2],
                 dut.u_dmem.mem[1], dut.u_dmem.mem[0]);

        if (dut.u_regfile.regs[1] !== 32'd55) begin
            $display("FAIL: x1 = %0d, expected 55", dut.u_regfile.regs[1]);
            errors = errors + 1;
        end
        // Reassemble the stored word from its 4 little-endian bytes.
        if ({dut.u_dmem.mem[3], dut.u_dmem.mem[2],
             dut.u_dmem.mem[1], dut.u_dmem.mem[0]} !== 32'd55) begin
            $display("FAIL: mem[0] word != 55");
            errors = errors + 1;
        end

        if (errors == 0) $display("ALL TESTS PASSED  (sum = 55)");
        else             $display("%0d TEST(S) FAILED", errors);
        $finish;
    end
endmodule

`default_nettype wire
