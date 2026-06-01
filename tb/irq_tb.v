// =====================================================================
// irq_tb.v  -  Run the timer-interrupt demo on the SoC.
// The ISR fires asynchronously while main() spins; the program halts
// itself via syscon once it has observed enough interrupts.
// =====================================================================
`timescale 1ns/1ps
`default_nettype none
module irq_tb;
    reg clk = 0, rst = 1;
    wire [31:0] pc, instr;

    soc #(.INIT_FILE("sw/irqdemo.hex"), .DATA_INIT("sw/irqdemo_data.hex")) dut (
        .clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr)
    );
    always #5 clk = ~clk;

    wire [31:0] ram_ticks = {dut.u_ram.mem[3], dut.u_ram.mem[2],
                             dut.u_ram.mem[1], dut.u_ram.mem[0]};
    initial begin
        $dumpfile("build/irq_tb.vcd"); $dumpvars(0, irq_tb);
        $display("---- UART output ----");
        repeat (3) @(posedge clk); #1; rst = 0;
        repeat (1000000) @(posedge clk);
        $display("\n[tb] TIMEOUT"); $finish;
    end
    final $display("---------------------\nfinal ticks stored in RAM = %0d", ram_ticks);
endmodule
`default_nettype wire
