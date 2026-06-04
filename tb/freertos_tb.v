`timescale 1ns/1ps
`default_nettype none
module freertos_tb;
    reg clk=0, rst=1; wire [31:0] pc, instr;
    soc_rtos #(.INIT_FILE("sw/freertos/fr.hex"), .DATA_INIT("sw/freertos/fr_data.hex"),
               .IMEM_WORDS(16384), .RAM_BYTES(131072)) dut (
        .clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr));
    always #5 clk = ~clk;
    initial begin
        $display("---- FreeRTOS on RV32IMA (soc_rtos) ----");
        repeat(3) @(posedge clk); #1; rst=0;
        repeat(3000000) @(posedge clk); $display("[tb] TIMEOUT"); $finish;
    end
endmodule
`default_nettype wire
