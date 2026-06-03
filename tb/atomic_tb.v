`timescale 1ns/1ps
`default_nettype none
module atomic_tb;
    reg clk=0, rst=1; wire [31:0] pc, instr;
    soc #(.INIT_FILE("sw/at.hex"), .DATA_INIT("sw/at_data.hex")) dut (
        .clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr));
    always #5 clk = ~clk;
    initial begin
        $dumpfile("build/atomic_tb.vcd"); $dumpvars(0, atomic_tb);
        $display("---- RV32A atomic operations ----");
        repeat(3) @(posedge clk); #1; rst=0;
        repeat(400000) @(posedge clk); $display("[tb] TIMEOUT"); $finish;
    end
endmodule
`default_nettype wire
