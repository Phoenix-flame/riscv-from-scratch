`timescale 1ns/1ps
`default_nettype none
module ill_tb;
    reg clk=0, rst=1; wire [31:0] pc, instr;
    soc #(.INIT_FILE("sw/ill.hex"), .DATA_INIT("sw/ill_data.hex")) dut (
        .clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr));
    always #5 clk = ~clk;
    initial begin
        $dumpfile("build/ill_tb.vcd"); $dumpvars(0, ill_tb);
        $display("---- UART output ----");
        repeat(3) @(posedge clk); #1; rst=0;
        repeat(500000) @(posedge clk); $display("[tb] TIMEOUT"); $finish;
    end
endmodule
`default_nettype wire
