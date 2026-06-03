## =====================================================================
## zynq7010.xdc  -  Constraints for a Zynq-7010 board (e.g. Digilent Zybo Z7-10)
## ---------------------------------------------------------------------
## IMPORTANT: pin assignments are board-specific. The values below match
## the Digilent Zybo Z7-10, but ALWAYS verify against your board's official
## master XDC before programming hardware -- a wrong pin can be harmless or
## not, depending on the board. Lines are commented with the board net name.
##
## The design uses ONLY the PL (programmable logic): the RISC-V core runs
## from block RAM and the PS (ARM/DDR) is not instantiated. The board's
## USB-UART is usually wired to the PS, so route uart_tx to a Pmod pin and
## attach a 3.3 V USB-UART adapter's RX there.
## =====================================================================

## ---- 125 MHz system clock (Zybo Z7 "sysclk", net SYSCLK) ----
set_property -dict { PACKAGE_PIN K17  IOSTANDARD LVCMOS33 } [get_ports clk_125]
create_clock -name sys_clk -period 8.000 [get_ports clk_125]

## ---- reset button (Zybo Z7 BTN0) : active-high ----
set_property -dict { PACKAGE_PIN K18  IOSTANDARD LVCMOS33 } [get_ports btn_rst]

## ---- program-halted LED (Zybo Z7 LD0) ----
set_property -dict { PACKAGE_PIN M14  IOSTANDARD LVCMOS33 } [get_ports {led[0]}]

## ---- UART TX -> Pmod JE pin 1 (net JE1). Connect adapter RX here. ----
set_property -dict { PACKAGE_PIN V12  IOSTANDARD LVCMOS33 } [get_ports uart_tx]

## The core's fabric clock is slow-path limited (combinational divide +
## the multi-cycle memory path). If timing fails at 125 MHz, drive the SoC
## from an MMCM-divided clock (e.g. 50 MHz) and set CLKS_PER_BIT to
## clk_freq/115200 to keep the UART baud correct.
