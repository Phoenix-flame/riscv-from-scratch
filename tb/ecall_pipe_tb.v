`timescale 1ns/1ps
`default_nettype none
module ecall_pipe_tb;
    reg clk=0, rst=1; wire [31:0] pc, instr;
    soc_pipe #(.INIT_FILE("sw/ec.hex"), .DATA_INIT("sw/ec_data.hex")) dut (
        .clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr));
    always #5 clk = ~clk;
    initial begin
        $dumpfile("build/ecall_pipe_tb.vcd"); $dumpvars(0, ecall_pipe_tb);
        $display("---- pipelined core, UART output ----");
        repeat(3) @(posedge clk); #1; rst=0;
        repeat(2000000) @(posedge clk); $display("[tb] TIMEOUT"); $finish;
    end
endmodule
`default_nettype wire
