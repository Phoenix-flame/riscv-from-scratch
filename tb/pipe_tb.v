// Run the SAME programs the single-cycle core ran, on the pipeline,
// and check the architectural results match exactly.
`timescale 1ns/1ps
`default_nettype none
module pipe_tb;
    reg clk=0, rst=1;
    wire [31:0] pc, instr;
    integer errors=0, c;

    cpu_pipe #(.INIT_FILE("sw/test_datapath.hex")) dut (
        .clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr));
    always #5 clk = ~clk;

    task chk; input [4:0] n; input [31:0] exp; begin
        if (dut.u_regfile.regs[n] !== exp) begin
            $display("FAIL x%0d = %h, expected %h", n, dut.u_regfile.regs[n], exp);
            errors=errors+1;
        end else $display("ok   x%0d = %h", n, dut.u_regfile.regs[n]);
    end endtask

    initial begin
        $dumpfile("build/pipe_tb.vcd"); $dumpvars(0, pipe_tb);
        rst=1; repeat(2) @(posedge clk); #1; rst=0;
        // pipeline needs more cycles (fill + stalls + flushes)
        for (c=0;c<80;c=c+1) @(posedge clk);
        #1;
        $display("---- pipelined results (must match single-cycle) ----");
        chk(5'd1,32'd5); chk(5'd2,32'd7); chk(5'd3,32'd12); chk(5'd4,32'd2);
        chk(5'd5,32'd12);                 // sw then lw round-trip
        chk(5'd6,32'd99);                 // beq not taken -> ran
        chk(5'd7,32'd0);                  // bne taken -> skipped (flush)
        chk(5'd8,32'd1); chk(5'd9,32'h30);
        if (dut.u_dmem.mem[0]!==8'h0C) begin $display("FAIL mem[0]"); errors=errors+1; end
        else $display("ok   mem[0] = 0c");
        $display("--------------------------------------------------");
        if (errors==0) $display("ALL TESTS PASSED (pipeline matches single-cycle)");
        else $display("%0d TEST(S) FAILED", errors);
        $finish;
    end
endmodule
`default_nettype wire
