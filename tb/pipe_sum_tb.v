`timescale 1ns/1ps
`default_nettype none
module pipe_sum_tb;
    reg clk=0, rst=1; wire [31:0] pc, instr; integer c;
    cpu_pipe #(.INIT_FILE("sw/sum.hex")) dut (.clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr));
    always #5 clk = ~clk;
    initial begin
        $dumpfile("build/pipe_sum_tb.vcd"); $dumpvars(0, pipe_sum_tb);
        rst=1; repeat(2) @(posedge clk); #1; rst=0;
        for (c=0;c<200;c=c+1) @(posedge clk); #1;
        $display("x1 (sum 1..10) = %0d  %s", dut.u_regfile.regs[1],
                 (dut.u_regfile.regs[1]==55)?"PASS":"FAIL");
        $display("mem[0]        = %0d  %s",
                 {dut.u_dmem.mem[3],dut.u_dmem.mem[2],dut.u_dmem.mem[1],dut.u_dmem.mem[0]},
                 ({dut.u_dmem.mem[3],dut.u_dmem.mem[2],dut.u_dmem.mem[1],dut.u_dmem.mem[0]}==55)?"PASS":"FAIL");
        $finish;
    end
endmodule
`default_nettype wire
