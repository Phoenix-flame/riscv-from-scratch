// =====================================================================
// fpga_top_tb.v  -  End-to-end: run the program on the synthesizable
// top and decode the REAL serial line back into characters.
// ---------------------------------------------------------------------
// This exercises the same path the Zynq PL would: program in BRAM, CPU
// executes, bytes are serialized out uart_tx. A small UART receiver
// model here samples that pin and prints what it decodes -- so the text
// you see came out a genuine serializer, not $write.
// =====================================================================
`timescale 1ns/1ps
`default_nettype none

module fpga_top_tb;
    // Use a tiny bit period so the test runs quickly.
    localparam CLKS_PER_BIT = 8;
    localparam CLK_PERIOD   = 10;
    localparam BIT_NS       = CLKS_PER_BIT * CLK_PERIOD;

    reg        clk = 0, rstn = 0;
    wire       uart_tx;
    wire [3:0] led;

    // CLK_FREQ/BAUD = CLKS_PER_BIT; pick values whose ratio is 8.
    fpga_top #(
        .CLK_FREQ_HZ(8), .BAUD(1),
        .INIT_FILE("sw/socdemo.hex"), .DATA_INIT("sw/socdemo_data.hex")
    ) dut (
        .clk(clk), .rstn(rstn), .uart_tx(uart_tx), .led(led)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // ---- UART receiver model: decode uart_tx and print chars ----
    reg [7:0] rxb;
    integer   i;
    initial begin
        $dumpfile("build/fpga_top_tb.vcd");
        $dumpvars(0, fpga_top_tb);
        repeat (4) @(negedge clk); rstn = 1;   // release reset

        $display("---- decoded from the real uart_tx pin ----");
        forever begin
            @(negedge uart_tx);          // start bit
            #(BIT_NS + BIT_NS/2);        // center of data bit 0
            for (i = 0; i < 8; i = i + 1) begin rxb[i] = uart_tx; #(BIT_NS); end
            $write("%c", rxb);
        end
    end

    // Stop once the program signals done via the LED (syscon write).
    initial begin
        wait (led[0] == 1'b1);
        #(BIT_NS*12);                    // let the last byte finish
        $display("\n-------------------------------------------");
        $display("program signaled done (led = %b)", led);
        $finish;
    end

    // Safety timeout.
    initial begin
        #(50_000_000);
        $display("\n[tb] TIMEOUT");
        $finish;
    end
endmodule

`default_nettype wire
