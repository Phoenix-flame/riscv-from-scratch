// =====================================================================
// cpu_tb.v  -  Run a real program through the single-cycle CPU and
//              check the resulting register values.
// =====================================================================
`timescale 1ns/1ps
`default_nettype none

module cpu_tb;
    reg clk, rst;
    wire [31:0] pc, instr;
    integer errors = 0;

    cpu #(.INIT_FILE("sw/test_datapath.hex")) dut (
        .clk(clk), .rst(rst),
        .pc_out(pc), .instr_out(instr)
    );

    initial clk = 0;
    always #5 clk = ~clk;       // 10 ns period

    // Check a register by reaching into the register file.
    task check_reg;
        input [4:0]  n;
        input [31:0] expected;
        begin
            if (dut.u_regfile.regs[n] !== expected) begin
                $display("FAIL x%0d = %h, expected %h",
                         n, dut.u_regfile.regs[n], expected);
                errors = errors + 1;
            end else
                $display("ok   x%0d = %h", n, dut.u_regfile.regs[n]);
        end
    endtask

    integer c;
    initial begin
        $dumpfile("build/cpu_tb.vcd");
        $dumpvars(0, cpu_tb);

        // Reset for one cycle, then let it run.
        rst = 1; @(posedge clk); #1; rst = 0;

        // Trace the first instructions so we can watch the PC walk.
        for (c = 0; c < 20; c = c + 1) begin
            @(posedge clk); #1;
            $display("  cycle %0d: pc=%h instr=%h", c, pc, instr);
        end

        $display("-------------------- register check --------------------");
        check_reg(5'd1, 32'd5);          // addi
        check_reg(5'd2, 32'd7);
        check_reg(5'd3, 32'd12);         // add
        check_reg(5'd4, 32'd2);          // sub
        check_reg(5'd5, 32'd12);         // lw  (proves sw+lw round trip)
        check_reg(5'd6, 32'd99);         // beq not taken -> this ran
        check_reg(5'd7, 32'd0);          // bne taken -> this was SKIPPED
        check_reg(5'd8, 32'd1);          // landed after the taken branch
        check_reg(5'd9, 32'h30);         // jal return address = PC+4

        // Also confirm the store actually hit data memory[0].
        if (dut.u_dmem.mem[0] !== 8'h0C) begin
            $display("FAIL mem[0] = %h, expected 0c", dut.u_dmem.mem[0]);
            errors = errors + 1;
        end else
            $display("ok   mem[0] = %h (the stored 12)", dut.u_dmem.mem[0]);

        $display("--------------------------------------------------------");
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d TEST(S) FAILED", errors);
        $finish;
    end
endmodule

`default_nettype wire
