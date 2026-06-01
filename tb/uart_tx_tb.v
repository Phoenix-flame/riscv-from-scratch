// =====================================================================
// uart_tx_tb.v  -  Verify the real UART transmitter by sampling the
// serial line and reconstructing the transmitted bytes.
// =====================================================================
`timescale 1ns/1ps
`default_nettype none

module uart_tx_tb;
    localparam CLKS_PER_BIT = 8;       // small for a fast test
    localparam CLK_PERIOD   = 10;      // ns
    localparam BIT_NS       = CLKS_PER_BIT * CLK_PERIOD;

    reg        clk = 0, rst = 1;
    reg  [7:0] data;
    reg        start = 0;
    wire       tx, busy;
    integer    errors = 0;

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) dut (
        .clk(clk), .rst(rst), .data(data), .start(start),
        .tx(tx), .busy(busy)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // Receive one byte by sampling the line at each bit center.
    task recv_byte;
        output [7:0] b;
        integer i;
        begin
            @(negedge tx);              // wait for the start bit
            #(BIT_NS + BIT_NS/2);       // move to the center of data bit 0
            for (i = 0; i < 8; i = i + 1) begin
                b[i] = tx;              // LSB first
                #(BIT_NS);
            end
            // now at the stop bit
            if (tx !== 1'b1) begin
                $display("FAIL: stop bit was %b, expected 1", tx);
                errors = errors + 1;
            end
        end
    endtask

    // Send a byte through the DUT.
    task send_byte;
        input [7:0] b;
        begin
            @(negedge clk);
            data = b; start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    reg [7:0] got;
    initial begin
        $dumpfile("build/uart_tx_tb.vcd");
        $dumpvars(0, uart_tx_tb);

        repeat (3) @(negedge clk); rst = 0;

        // Send 'A' (0x41) and check the line carried it.
        fork
            send_byte(8'h41);
            begin recv_byte(got);
                  if (got !== 8'h41) begin
                      $display("FAIL: received %h, expected 41", got);
                      errors = errors + 1;
                  end else $display("ok   transmitted 0x41 -> received 0x%h ('%c')", got, got);
            end
        join
        wait (!busy); @(negedge clk);

        // Send 'Z' (0x5A).
        fork
            send_byte(8'h5A);
            begin recv_byte(got);
                  if (got !== 8'h5A) begin
                      $display("FAIL: received %h, expected 5A", got);
                      errors = errors + 1;
                  end else $display("ok   transmitted 0x5A -> received 0x%h ('%c')", got, got);
            end
        join
        wait (!busy);

        $display("--------------------------------------------------");
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d TEST(S) FAILED", errors);
        $finish;
    end
endmodule

`default_nettype wire
