// =====================================================================
// fpga_top_rtos.v  -  Zynq-7010 top level that runs FreeRTOS in the PL
// ---------------------------------------------------------------------
// Wraps soc_rtos_fpga: the RV32IM multi-cycle BRAM core runs the FreeRTOS
// kernel entirely from block RAM, prints over a real UART pin, and lights
// an LED when the demo halts. Pins come from constraints/zynq7010.xdc
// (same port names as fpga_top_full): clk_125 / btn_rst / uart_tx / led.
//
// For correct 1 kHz ticks on real 125 MHz hardware, build the image with
// configCPU_CLOCK_HZ = 125000000 (the shipped fr_fpga.hex uses a smaller
// value so it ticks quickly in simulation).
// =====================================================================
`default_nettype none

module fpga_top_rtos #(
    parameter IMEM_INIT = "",
    parameter DMEM_INIT = ""
) (
    input  wire       clk_125,
    input  wire       btn_rst,
    output wire       uart_tx,
    output wire [0:0] led
);
    reg [1:0] rsync = 2'b11;
    always @(posedge clk_125) rsync <= {rsync[0], btn_rst};
    wire rst = rsync[1];

    soc_rtos_fpga #(
        .ROM_WORDS(16384), .RAM_WORDS(16384),
        .IMEM_INIT(IMEM_INIT), .DMEM_INIT(DMEM_INIT),
        .CLKS_PER_BIT(1085)              // 125 MHz / 115200 baud
    ) u_soc (
        .clk(clk_125), .rst(rst),
        .uart_tx_pin(uart_tx), .halted(led[0])
    );
endmodule

`default_nettype wire
