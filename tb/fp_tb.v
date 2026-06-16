`timescale 1ns/1ps
`default_nettype none
// Runs the compiled rv32imf fp_demo on soc_f and checks the 15 results it
// writes to RAM (0x600..0x638) against host-computed float32 bit patterns in
// tb/fp_expected.hex. The same program image initialises both the instruction
// ROM and the data RAM, so the float literals in .rodata are readable as data.
module fp_tb;
    reg clk=0, rst=1; always #5 clk=~clk;
    wire halted;

    soc_f #(.ROM_WORDS(4096), .RAM_WORDS(4096),
            .IMEM_INIT("sw/fp_demo.hex"), .DMEM_INIT("sw/fp_demo.hex")) dut (
        .clk(clk), .rst(rst), .halted(halted)
    );

    function [31:0] rd; input [31:0] a; rd = dut.u_ram.mem[a>>2]; endfunction

    reg [31:0] exp [0:14];
    integer i, fails, g;
    reg [31:0] got;

    initial begin
        $readmemh("tb/fp_expected.hex", exp);
        repeat(3) @(posedge clk); #1; rst = 0;

        // run until SYSCON halt (sentinel 0x600D at 0x6F0) or timeout
        g = 0;
        while (!halted && g < 200000) begin @(posedge clk); g = g + 1; end

        if (rd(32'h6F0) !== 32'h0000600D)
            $display("WARN: sentinel not set (got %h) after %0d cycles", rd(32'h6F0), g);

        fails = 0;
        for (i = 0; i < 15; i = i + 1) begin
            got = rd(32'h600 + i*4);
            if (got !== exp[i]) begin
                fails = fails + 1;
                $display("FAIL result[%0d] @0x%03h: got %h exp %h", i, 32'h600+i*4, got, exp[i]);
            end
        end

        $display("");
        if (fails == 0) $display("FP-INTEGRATION: ALL %0d RESULTS PASS (halt @ %0d cycles)", 15, g);
        else            $display("FP-INTEGRATION: %0d/%0d FAIL", fails, 15);
        $finish;
    end
endmodule
`default_nettype wire
