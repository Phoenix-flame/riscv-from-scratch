`timescale 1ns/1ps
`default_nettype none
module freertos_fpga_tb;
    reg clk=0, rst=1; wire tx, halted;
    soc_rtos_fpga #(.ROM_WORDS(16384), .RAM_WORDS(16384),
                    .IMEM_INIT("sw/freertos/fr_fpga.hex"),
                    .DMEM_INIT("sw/freertos/fr_fpga.hex"),
                    .CLKS_PER_BIT(4)) dut (
        .clk(clk), .rst(rst), .uart_tx_pin(tx), .halted(halted));
    always #5 clk = ~clk;
    // capture bytes the CPU writes to UART TX (physical addr 0x10000000)
    always @(posedge clk)
        if (!rst && dut.sel_uart && dut.wr_any && (dut.daddr[7:0]==8'h00))
            $write("%c", dut.dwdata[7:0]);
    initial begin
        $display("---- FreeRTOS on synthesizable soc_rtos_fpga (cpu_mc + BRAM) ----");
        repeat(3) @(posedge clk); #1; rst=0;
        begin : run integer c;
          for (c=0;c<8000000;c=c+1) begin @(posedge clk); #1;
            if (halted) begin $display("\n[soc] halted (LED on)"); $finish; end
          end
          $display("\n[tb] TIMEOUT"); $finish;
        end
    end
endmodule
`default_nettype wire
