`timescale 1ns/1ps
`default_nettype none
// End-to-end test of UART interrupts + receive-to-idle. The host sends a
// whole message as a burst then goes quiet; the SoC collects it via RX
// interrupts, fires the IDLE interrupt, and echoes the entire message back.
module uart_irq_tb;
    reg clk=0, rst=1; always #5 clk=~clk;
    wire soc_tx, soc_halted; reg host_line;

    soc_uart_fpga #(.ROM_WORDS(4096), .RAM_WORDS(4096),
                    .IMEM_INIT("sw/uart_irq.hex"), .DMEM_INIT("sw/uart_irq.hex"),
                    .DEF_CLKS(64)) dut (
        .clk(clk), .rst(rst), .uart_rx_pin(host_line),
        .uart_tx_pin(soc_tx), .halted(soc_halted));

    reg [7:0] h_data; reg h_send; wire h_busy, h_tx;
    uart_tx_cfg host_tx(.clk(clk),.rst(rst),.send(h_send),.data(h_data),
        .clks_per_bit(16'd64),.data_bits(4'd8),.parity_mode(2'd0),.stop2(1'b0),
        .tx(h_tx),.busy(h_busy));
    always @(*) host_line = h_tx;

    wire [7:0] h_rxd; wire h_rxv;
    uart_rx host_rx(.clk(clk),.rst(rst),.rx(soc_tx),
        .clks_per_bit(16'd64),.data_bits(4'd8),.parity_mode(2'd0),.stop2(1'b0),
        .idle_bits(5'd0),.data(h_rxd),.valid(h_rxv),.frame_err(),.parity_err(),.idle());

    reg [7:0] echo [0:255]; integer recv=0;
    always @(posedge clk) if (h_rxv) begin echo[recv]=h_rxd; recv=recv+1; end

    task send_byte(input [7:0] b); begin
        while (h_busy) @(posedge clk);
        @(negedge clk); h_data=b; h_send=1; @(negedge clk); h_send=0;
    end endtask

    integer fails=0;
    task send_msg_check(input [8*8-1:0] m, input integer n);
        integer k, base, w; begin
        base = recv;
        for (k=0;k<n;k=k+1) send_byte(m[(n-1-k)*8 +: 8]);
        w=0; while ((recv-base) < n && w<60000) begin @(posedge clk); w=w+1; end
        if ((recv-base) < n) begin
            $display("  FAIL: only %0d/%0d bytes echoed back", recv-base, n); fails=fails+1;
        end else begin
            $write("  whole message echoed: \"");
            for (k=0;k<n;k=k+1) $write("%c", echo[base+k]);
            $write("\"");
            for (k=0;k<n;k=k+1) if (echo[base+k] !== m[(n-1-k)*8 +: 8]) fails=fails+1;
            if (fails==0) $display("  (match)"); else $display("  (MISMATCH)");
        end
    end endtask

    initial begin
        h_send=0; h_data=0; host_line=1;
        repeat(4) @(posedge clk); #1; rst=0;
        repeat(2500) @(posedge clk);
        $display("=== receive-to-idle: a whole message is collected then echoed ===");
        $display("host sends \"HELLO\":"); send_msg_check("HELLO", 5);
        $display("host sends \"Hi!\":");   send_msg_check("Hi!", 3);
        if (fails==0) $display("UART IRQ RX-TO-IDLE: ALL PASS");
        else          $display("UART IRQ RX-TO-IDLE: %0d FAIL", fails);
        $finish;
    end
endmodule
`default_nettype wire
