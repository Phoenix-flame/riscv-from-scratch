## =====================================================================
## openzynq_linux.xdc  -  fpga_top_linux on the OpenZynq / Mitra-7010 board
## ---------------------------------------------------------------------
## Step 54. The pins of fpga_top_boot (openzynq_boot.xdc), with UART RX on
## K19 = JM1 pin 22, next to TX on J18 = JM1 pin 21 (OpenZynq's
## boards/mitra7010/pinout.md: bank 35, 3.3 V, nothing else on the header).
## Wire a 3.3 V USB-serial adapter: its RX to JM1 pin 21, its TX to JM1
## pin 22, its GND to JM1 pin 3 or 4. Do not connect its 5 V / 3.3 V.
## The PS side (DDR, FCLK0, M_AXI_GP0, S_AXI_HP0) needs no pins here.
## =====================================================================
set_property PACKAGE_PIN U18     [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
create_clock -period 20.000 -name sys_clk [get_ports clk]

set_property PACKAGE_PIN U19     [get_ports resetn]
set_property IOSTANDARD LVCMOS33 [get_ports resetn]

set_property PACKAGE_PIN R19     [get_ports led]
set_property IOSTANDARD LVCMOS33 [get_ports led]
set_property PACKAGE_PIN V13     [get_ports led2]
set_property IOSTANDARD LVCMOS33 [get_ports led2]

set_property PACKAGE_PIN J18     [get_ports uart_tx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]
set_property PACKAGE_PIN K19     [get_ports uart_rx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rx]
