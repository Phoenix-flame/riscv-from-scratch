`timescale 1ns/1ps
`default_nettype none
module md_tb;
    reg clk=0, rst=1; wire [31:0] pc, instr;
    soc #(.INIT_FILE("sw/md.hex"), .DATA_INIT("sw/md_data.hex")) dut (
        .clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr));
    always #5 clk = ~clk;
    wire [31:0] fact = {dut.u_ram.mem[3],dut.u_ram.mem[2],dut.u_ram.mem[1],dut.u_ram.mem[0]};
    initial begin
        $dumpfile("build/md_tb.vcd"); $dumpvars(0, md_tb);
        $display("---- UART output ----");
        repeat(3) @(posedge clk); #1; rst=0;
        repeat(1000000) @(posedge clk); $display("[tb] TIMEOUT"); $finish;
    end
    final $display("---------------------\n6! stored in RAM = %0d %s", fact, (fact==720)?"(PASS)":"(FAIL)");
endmodule
`default_nettype wire
