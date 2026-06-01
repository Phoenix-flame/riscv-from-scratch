# =====================================================================
# zynq.xdc  -  Constraints TEMPLATE for running fpga_top on a Zynq-7010
#              board (e.g. Zybo Z7-10, Arty Z7-10, Cora Z7-10).
# ---------------------------------------------------------------------
# IMPORTANT: pin locations are BOARD-specific, not chip-specific. The
# XC7Z010 is used on several boards with different pinouts. Copy the
# exact LOC/IOSTANDARD values from YOUR board's official "master XDC"
# (Digilent / your vendor provides one) and keep the port names below.
#
# Also note: on most Zynq dev boards the USB-UART bridge is wired to the
# PS (MIO pins), NOT the PL. To use THIS PL soft-UART you typically route
# uart_tx to a PMOD pin and connect an external USB-to-serial adapter
# (3.3V) -- adapter RX <- board uart_tx, and a common ground.
# =====================================================================

## ---- Clock (example: Zybo Z7 125 MHz system clock on K17) ----
set_property -dict { PACKAGE_PIN K17  IOSTANDARD LVCMOS33 } [get_ports clk]
create_clock -name sys_clk -period 8.000 [get_ports clk]   ;# 125 MHz
# If you use a different PL clock, set CLK_FREQ_HZ in fpga_top to match,
# and update the period above (period_ns = 1000 / freq_MHz).

## ---- Reset button (example: Zybo Z7 button BTN0 on K18) ----
## fpga_top uses active-low rstn; if your button is active-high, either
## invert in the XDC-connected wrapper or flip the polarity in fpga_top.
set_property -dict { PACKAGE_PIN K18  IOSTANDARD LVCMOS33 } [get_ports rstn]

## ---- UART TX out to a PMOD pin (example: Zybo Z7 PMOD JE pin 1) ----
set_property -dict { PACKAGE_PIN V12  IOSTANDARD LVCMOS33 } [get_ports uart_tx]

## ---- LEDs (example: Zybo Z7 LD0..LD3) ----
set_property -dict { PACKAGE_PIN M14  IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN M15  IOSTANDARD LVCMOS33 } [get_ports {led[1]}]
set_property -dict { PACKAGE_PIN G14  IOSTANDARD LVCMOS33 } [get_ports {led[2]}]
set_property -dict { PACKAGE_PIN D18  IOSTANDARD LVCMOS33 } [get_ports {led[3]}]

## ---- Tell timing about the asynchronous reset input ----
set_false_path -from [get_ports rstn]
