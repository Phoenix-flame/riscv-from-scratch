`timescale 1ns/1ps
`default_nettype none
module rtos_smoke_tb;
    reg clk=0, rst=1; wire [31:0] pc, instr;
    soc_rtos #(.INIT_FILE("sw/rs.hex"), .DATA_INIT("sw/rs_data.hex")) dut (
        .clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr));
    always #5 clk = ~clk;
    initial begin
        $dumpfile("build/rtos_smoke_tb.vcd"); $dumpvars(0, rtos_smoke_tb);
        $display("---- RTOS SoC smoke test ----");
        repeat(3) @(posedge clk); #1; rst=0;
        repeat(400000) @(posedge clk); $display("[tb] TIMEOUT"); $finish;
    end
endmodule
`default_nettype wire
