## =====================================================================
## zynq7010_uart.xdc  -  Constraints for fpga_top_uart (Zynq-7010 / Zybo Z7-10)
## ---------------------------------------------------------------------
## Same clock/reset/LED/TX pins as zynq7010.xdc, plus a UART RX pin.
## VERIFY every PACKAGE_PIN against your board's official master XDC before
## programming hardware. PL-only design (PS/DDR not used); route the UART to
## Pmod JE and connect a 3.3 V USB-UART adapter:
##     adapter RX  <-- uart_tx (JE1)
##     adapter TX  --> uart_rx (JE2)
##     adapter GND <-- board GND
## =====================================================================

## ---- 125 MHz system clock (net SYSCLK) ----
set_property -dict { PACKAGE_PIN K17  IOSTANDARD LVCMOS33 } [get_ports clk_125]
create_clock -name sys_clk -period 8.000 [get_ports clk_125]

## ---- reset button (BTN0), active-high ----
set_property -dict { PACKAGE_PIN K18  IOSTANDARD LVCMOS33 } [get_ports btn_rst]

## ---- program-halted LED (LD0) ----
set_property -dict { PACKAGE_PIN M14  IOSTANDARD LVCMOS33 } [get_ports {led[0]}]

## ---- UART TX -> Pmod JE1 (net JE1). Connect adapter RX here. ----
set_property -dict { PACKAGE_PIN V12  IOSTANDARD LVCMOS33 } [get_ports uart_tx]

## ---- UART RX <- Pmod JE2 (net JE2). Connect adapter TX here. ----
set_property -dict { PACKAGE_PIN W16  IOSTANDARD LVCMOS33 } [get_ports uart_rx]

## If timing fails at 125 MHz, drive the SoC from an MMCM-divided clock and
## set DEF_CLKS = clk_freq / baud to keep the UART rate correct.
