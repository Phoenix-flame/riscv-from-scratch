`timescale 1ns/1ps
`default_nettype none
module fpga_full_tb;
    reg clk=0, rst=1;
    wire tx, halted;
    // small CLKS_PER_BIT so the UART isn't slow in sim; we verify by
    // probing the byte written to the UART, not by decoding the serial line.
    soc_fpga #(.ROM_WORDS(1024), .RAM_WORDS(2048),
               .IMEM_INIT("sw/fp.hex"), .CLKS_PER_BIT(4)) dut (
        .clk(clk), .rst(rst), .uart_tx_pin(tx), .halted(halted));
    always #5 clk = ~clk;

    // capture each byte the CPU writes to UART TX (physical addr 0x10000000)
    always @(posedge clk) begin
        if (!rst && dut.sel_uart && dut.wr_any && (dut.daddr[7:0]==8'h00))
            $write("%c", dut.dwdata[7:0]);
    end

    initial begin
        $dumpfile("build/fpga_full_tb.vcd"); $dumpvars(0, fpga_full_tb);
        $write("---- UART output ----\n");
        repeat(3) @(posedge clk); #1; rst=0;
        // run until halted (or timeout)
        begin : run
            integer c;
            for (c=0;c<200000;c=c+1) begin
                @(posedge clk); #1;
                if (halted) begin
                    $write("\n[soc] CPU halted, LED on (program signaled done)\n");
                    $finish;
                end
            end
            $write("\n[tb] TIMEOUT\n"); $finish;
        end
    end
endmodule
`default_nettype wire
