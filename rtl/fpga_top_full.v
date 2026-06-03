// =====================================================================
// fpga_top_full.v  -  Top level for a Zynq-7010 (e.g. Zybo Z7-10)
// ---------------------------------------------------------------------
// Wraps the synthesizable SoC: the RISC-V core runs entirely in the PL
// from block RAM, prints over a real UART pin, and lights an LED when
// the program halts. The PS (ARM/DDR) is not used here.
//   clk_125  : 125 MHz PL clock (board oscillator)
//   btn_rst  : active-high reset button
//   uart_tx  : serial out (route to a Pmod / USB-UART adapter)
//   led[0]   : program-halted indicator
// =====================================================================
`default_nettype none

module fpga_top_full #(
    parameter IMEM_INIT = "",
    parameter DMEM_INIT = ""
) (
    input  wire       clk_125,
    input  wire       btn_rst,
    output wire       uart_tx,
    output wire [0:0] led
);
    // simple 2-FF reset synchronizer (btn_rst is active-high)
    reg [1:0] rsync = 2'b11;
    always @(posedge clk_125) rsync <= {rsync[0], btn_rst};
    wire rst = rsync[1];

    soc_fpga #(
        .ROM_WORDS(1024), .RAM_WORDS(2048),
        .IMEM_INIT(IMEM_INIT), .DMEM_INIT(DMEM_INIT),
        .CLKS_PER_BIT(1085)                 // 125 MHz / 115200 baud
    ) u_soc (
        .clk(clk_125), .rst(rst),
        .uart_tx_pin(uart_tx), .halted(led[0])
    );
endmodule

`default_nettype wire
