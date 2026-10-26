// =====================================================================
// fpga_top_boot.v  -  the boot platform on the OpenZynq / Mitra-7010 board
// ---------------------------------------------------------------------
// Step 51. soc_boot with MEMSYS = 1: the caches in front of block RAM --
// the 16 KiB boot ROM and 128 KiB of RAM (the Zynq-7010 has 240 KiB of
// block RAM in all), so the whole computer is in the PL and needs nothing
// from the PS. The ROM inside is the board build (make boot-board), which
// sets the UART divisor for 115200 baud from the 50 MHz PL oscillator;
// the RAM size it reports in the device tree is the one it probes.
//
//   clk      U18  50 MHz PL oscillator
//   resetn   U19  K1, active low
//   uart_tx  J18  JM1 pin 21 (3.3 V) -> a USB-serial adapter's RX
//   uart_rx  ---  any free 3.3 V pin <- the adapter's TX (see the .xdc)
//   led      R19  LED1: powered off (the test device)
//   led2     V13  LED2: heartbeat
//
// Send images with `stty -F /dev/ttyUSB0 115200 raw; cat prog.rvbi >
// /dev/ttyUSB0` after `tools/rvboot image prog.elf -o prog.rvbi`.
// =====================================================================
`default_nettype none

module fpga_top_boot #(
    parameter BOOTROM_INIT = "build/boot/board/rom.hex",
    parameter RAM_WORDS    = 32768                 // 128 KiB
) (
    input  wire clk,
    input  wire resetn,
    input  wire uart_rx,
    output wire uart_tx,
    output wire led,
    output wire led2
);
    reg [1:0] rs = 2'b11;                          // reset: synchronised, held while K1 is down
    always @(posedge clk) rs <= {rs[0], ~resetn};
    wire rst = rs[1];

    reg [24:0] beat = 25'd0;
    always @(posedge clk) beat <= beat + 25'd1;
    assign led2 = beat[24];

    wire halted;
    soc_boot #(.MEMSYS(1), .RAM_WORDS(RAM_WORDS), .BOOTROM_INIT(BOOTROM_INIT),
               .UART_DIV(16'd27)) u_soc (
        .clk(clk), .rst(rst), .uart_rx_pin(uart_rx), .uart_tx_pin(uart_tx),
        .halted(halted), .exit_code(), .warm_reset(),
        .m_axi_awaddr(), .m_axi_awlen(), .m_axi_awsize(), .m_axi_awburst(), .m_axi_awcache(),
        .m_axi_awprot(), .m_axi_awvalid(), .m_axi_awready(1'b0), .m_axi_wdata(), .m_axi_wstrb(),
        .m_axi_wlast(), .m_axi_wvalid(), .m_axi_wready(1'b0), .m_axi_bresp(2'b00),
        .m_axi_bvalid(1'b0), .m_axi_bready(), .m_axi_araddr(), .m_axi_arlen(), .m_axi_arsize(),
        .m_axi_arburst(), .m_axi_arcache(), .m_axi_arprot(), .m_axi_arvalid(),
        .m_axi_arready(1'b0), .m_axi_rdata(32'd0), .m_axi_rresp(2'b00), .m_axi_rlast(1'b0),
        .m_axi_rvalid(1'b0), .m_axi_rready());
    assign led = halted;
endmodule

`default_nettype wire
