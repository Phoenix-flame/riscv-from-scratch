`timescale 1ns/1ps
`default_nettype none
module sched_tb;
    reg clk=0, rst=1; wire [31:0] pc, instr;
    soc #(.INIT_FILE("sw/sch.hex")) dut (.clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr));
    always #5 clk = ~clk;
    initial begin
        $dumpfile("build/sched_tb.vcd"); $dumpvars(0, sched_tb);
        $display("---- two tasks, preemptively scheduled (A = taskA, b = taskB) ----");
        repeat(3) @(posedge clk); #1; rst=0;
        repeat(2000000) @(posedge clk); $display("\n[tb] TIMEOUT"); $finish;
    end
endmodule
`default_nettype wire
