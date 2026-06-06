// =====================================================================
// fpga_top_uart.v  -  Zynq-7010 top with the configurable UART (RX+TX)
// ---------------------------------------------------------------------
// Wraps soc_uart_fpga. The RV32IM BRAM core runs uart_echo from block
// RAM: it configures the UART (baud/data/parity/stop via the CONFIG
// register) and echoes every received byte. Pins in
// constraints/zynq7010_uart.xdc: clk_125 / btn_rst / uart_rx / uart_tx / led.
//
// uart_rx has a 2-FF synchronizer inside uart_rx.v, so the async pin is
// safe. For 115200 baud on real 125 MHz hardware keep DEF_CLKS=1085 and
// build uart_echo without -DCLKS (it defaults to 1085).
// =====================================================================
`default_nettype none

module fpga_top_uart #(
    parameter IMEM_INIT = "",
    parameter DMEM_INIT = ""
) (
    input  wire       clk_125,
    input  wire       btn_rst,
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire [0:0] led
);
    reg [1:0] rsync = 2'b11;
    always @(posedge clk_125) rsync <= {rsync[0], btn_rst};
    wire rst = rsync[1];

    soc_uart_fpga #(
        .ROM_WORDS(4096), .RAM_WORDS(4096),
        .IMEM_INIT(IMEM_INIT), .DMEM_INIT(DMEM_INIT),
        .DEF_CLKS(1085)                       // 125 MHz / 115200 baud
    ) u_soc (
        .clk(clk_125), .rst(rst),
        .uart_rx_pin(uart_rx), .uart_tx_pin(uart_tx), .halted(led[0])
    );
endmodule

`default_nettype wire
