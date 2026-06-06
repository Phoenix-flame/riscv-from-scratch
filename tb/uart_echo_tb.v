`timescale 1ns/1ps
`default_nettype none
module uart_echo_tb;
    reg clk=0, rst=1; always #5 clk=~clk;
    wire soc_tx, soc_halted;
    reg  host_line;                      // host -> soc rx

    soc_uart_fpga #(.ROM_WORDS(4096), .RAM_WORDS(4096),
                    .IMEM_INIT("sw/uart_echo.hex"), .DMEM_INIT("sw/uart_echo.hex"),
                    .DEF_CLKS(16)) dut (
        .clk(clk), .rst(rst), .uart_rx_pin(host_line),
        .uart_tx_pin(soc_tx), .halted(soc_halted));

    // host transmitter: drives the soc's rx pin
    reg [7:0] h_data; reg h_send; wire h_busy; wire h_tx;
    uart_tx_cfg host_tx(.clk(clk),.rst(rst),.send(h_send),.data(h_data),
        .clks_per_bit(16'd16),.data_bits(4'd8),.parity_mode(2'd0),.stop2(1'b0),
        .tx(h_tx),.busy(h_busy));
    always @(*) host_line = h_tx;        // wire host TX -> soc RX

    // host receiver: captures the soc's tx pin (the echoed byte)
    wire [7:0] h_rxd; wire h_rxv;
    uart_rx host_rx(.clk(clk),.rst(rst),.rx(soc_tx),
        .clks_per_bit(16'd16),.data_bits(4'd8),.parity_mode(2'd0),.stop2(1'b0),
        .data(h_rxd),.valid(h_rxv),.frame_err(),.parity_err());

    reg [7:0] echoed; reg eflag;
    always @(posedge clk) if (h_rxv) begin echoed<=h_rxd; eflag<=1'b1; end

    integer fails=0;
    task send_expect(input [7:0] b); integer n; begin
        eflag=0;
        while (h_busy) @(posedge clk);
        @(negedge clk); h_data=b; h_send=1; @(negedge clk); h_send=0;
        n=0; while(!eflag && n<8000) begin @(posedge clk); n=n+1; end
        if (!eflag)            begin $display("  FAIL '%c': no echo", b); fails=fails+1; end
        else if (echoed!==b)   begin $display("  FAIL: sent %02h echoed %02h", b, echoed); fails=fails+1; end
        else $display("  sent '%c' (%02h) -> echoed '%c' (%02h)", b, b, echoed, echoed);
    end endtask

    initial begin
        h_send=0; h_data=0; host_line=1;
        repeat(4) @(posedge clk); #1; rst=0;
        repeat(1200) @(posedge clk);     // let firmware boot and configure the UART
        $display("=== UART echo over RX/TX (host <-> CPU) ===");
        send_expect("H"); send_expect("i"); send_expect("!"); send_expect(8'h5A);
        if (fails==0) $display("UART ECHO: ALL PASS"); else $display("UART ECHO: %0d FAIL", fails);
        $finish;
    end
endmodule
`default_nettype wire
