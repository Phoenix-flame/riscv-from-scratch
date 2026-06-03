`timescale 1ns/1ps
`default_nettype none
module mmu_hw_tb;
    reg clk=0, rst=1; wire tx, halted;
    soc_fpga_mmu #(.ROM_WORDS(1024), .RAM_WORDS(4096),
                   .IMEM_INIT("sw/mh.hex"), .CLKS_PER_BIT(4)) dut (
        .clk(clk), .rst(rst), .uart_tx_pin(tx), .halted(halted));
    always #5 clk = ~clk;
    always @(posedge clk)
        if (!rst && dut.sel_uart && dut.wr_any && (dut.daddr[7:0]==8'h00))
            $write("%c", dut.dwdata[7:0]);
    initial begin
        $dumpfile("build/mmu_hw_tb.vcd"); $dumpvars(0, mmu_hw_tb);
        $write("---- UART output (synthesizable MMU core) ----\n");
        repeat(3) @(posedge clk); #1; rst=0;
        begin : run integer c;
            for (c=0;c<300000;c=c+1) begin @(posedge clk); #1;
                if (halted) begin $write("[soc] halted (LED on)\n"); $finish; end
            end
            $write("[tb] TIMEOUT\n"); $finish;
        end
    end
endmodule
`default_nettype wire
