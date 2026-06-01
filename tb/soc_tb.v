// =====================================================================
// soc_tb.v  -  Run the peripheral demo on the SoC.
// The program halts itself via the syscon device ($finish), so the
// testbench just provides a clock/reset and a safety timeout.
// =====================================================================
`timescale 1ns/1ps
`default_nettype none

module soc_tb;
    reg clk, rst;
    wire [31:0] pc, instr;

    soc #(.INIT_FILE("sw/socdemo.hex")) dut (
        .clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    wire [31:0] delta = {dut.u_ram.mem[3], dut.u_ram.mem[2],
                         dut.u_ram.mem[1], dut.u_ram.mem[0]};

    initial begin
        $dumpfile("build/soc_tb.vcd");
        $dumpvars(0, soc_tb);

        $display("---- UART output ----");
        rst = 1; @(posedge clk); #1; rst = 0;

        // Safety timeout: the program should halt itself well before this.
        repeat (2000) @(posedge clk);
        $display("\n[testbench] TIMEOUT - syscon halt never happened");
        $finish;
    end

    // Print the measured timer delta right before the sim ends.
    final $display("\n---------------------\ntimer delta measured by program = %0d cycles",
                   delta);
endmodule

`default_nettype wire
