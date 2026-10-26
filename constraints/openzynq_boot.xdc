## =====================================================================
## openzynq_boot.xdc  -  fpga_top_boot on the OpenZynq / Mitra-7010 board
## ---------------------------------------------------------------------
## Clock, reset, LEDs and UART TX are the pins tools/rvgen uses for this
## board (Step 45). UART RX has no pin anywhere in this repository yet:
## pick a free 3.3 V pin on JM1 (bank 35, next to J18) from OpenZynq's
## boards/mitra7010/pinout.md and put it below -- Vivado stops at the
## placeholder until you do, rather than guessing a pin on real hardware.
## Wire a 3.3 V USB-serial adapter: its RX to uart_tx (J18 = JM1 pin 21),
## its TX to uart_rx, GND to JM1 pin 3/4.
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

set_property PACKAGE_PIN SET_ME_FROM_PINOUT_MD [get_ports uart_rx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rx]
