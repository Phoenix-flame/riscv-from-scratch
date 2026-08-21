# =====================================================================
# spartan6/Makefile  -  simulate, build firmware, synthesise, program
# ---------------------------------------------------------------------
#   make test          every self-checking simulation (needs iverilog)
#   make riscv-tests   the official suite against this core
#   make firmware      sw/hello.hex  (goes into the bitstream)
#   make bit           synthesise with ISE 14.7 -> syn/s6_top.bit
#   make prog          load the bitstream onto the board
#   make upload        send a program to the running bootloader
#   make clean
#
# Run everything from this directory: the $readmemh paths in the
# testbenches are relative to it.
# =====================================================================
# -Wno-timescale: the RTL is timescale-free on purpose (it has no delays and
# has to synthesise); only the testbenches declare one, and iverilog warns
# about the mix on every single module.
IV   = iverilog -g2012 -Wall -Wno-timescale
VVP  = vvp
B    = build
$(shell mkdir -p $(B))

CORE_RTL = rtl/s6_regfile.v rtl/s6_rvc.v rtl/s6_muldiv.v rtl/s6_csr.v \
           rtl/s6_core.v
SOC_RTL  = $(CORE_RTL) rtl/s6_ram.v rtl/s6_fifo.v rtl/s6_uart_tx.v \
           rtl/s6_uart_rx.v rtl/s6_uart.v rtl/s6_clint.v rtl/s6_gpio.v \
           rtl/s6_sram.v rtl/s6_soc.v

# Tools and the serial port the board shows up on (FT2232 channel B).
# On Windows that port is a COM device and the Store's "python3" is a stub
# that only opens the Store, so both defaults change; tools/s6.ps1 finds the
# port by itself and needs no make at all (docs/programming.md, "Windows").
ifeq ($(OS),Windows_NT)
PORT   ?= COM4
PYTHON ?= python
else
PORT   ?= /dev/ttyUSB1
PYTHON ?= python3
endif
OFL    ?= openFPGALoader
# Writing to SPI flash goes through a spiOverJtag bitstream, and
# openFPGALoader picks it by device+package -- it cannot guess.
FPGA_PART ?= xc6slx9tqg144

.PHONY: all test muldiv uart soc bootsim riscv-tests firmware boot app \
        bit bit-tcl prog prog-flash upload term lint clean

all: test

# =====================================================================
# Simulation
# =====================================================================
test: muldiv uart soc bootsim
	@echo "--- all spartan6 simulations passed ---"

muldiv:
	$(IV) -o $(B)/s6_muldiv_tb.vvp rtl/s6_muldiv.v tb/s6_muldiv_tb.v
	$(VVP) $(B)/s6_muldiv_tb.vvp

uart:
	$(IV) -o $(B)/s6_uart_tb.vvp rtl/s6_uart.v rtl/s6_uart_tx.v \
	      rtl/s6_uart_rx.v rtl/s6_fifo.v tb/s6_uart_tb.v
	$(VVP) $(B)/s6_uart_tb.vvp

# The full SoC running the real firmware, with a behavioural
# IS61WV5128BLL on the SRAM pins. Takes about a minute: the CPU spends
# most of it waiting for the UART, which is the point.
soc: sw/hello.hex
	$(IV) -o $(B)/s6_soc_tb.vvp $(SOC_RTL) tb/s6_sram_model.v tb/s6_soc_tb.v
	$(VVP) $(B)/s6_soc_tb.vvp

# The serial bootloader, uploaded to and executed from block RAM.
bootsim: sw/boot.hex
	$(IV) -o $(B)/s6_boot_tb.vvp $(SOC_RTL) tb/s6_boot_tb.v
	$(VVP) $(B)/s6_boot_tb.vvp

# The official riscv-tests suite (rv32ui / um / ua / uc), driven by the
# parent repo's runner. `s6_sf` re-runs the whole thing with FAST_FETCH=0.
riscv-tests:
	cd .. && $(PYTHON) tools/rvtests --core s6

riscv-tests-all:
	cd .. && $(PYTHON) tools/rvtests --core s6
	cd .. && $(PYTHON) tools/rvtests --core s6_sf

# A syntax/elaboration check of everything, including the FPGA top.
lint:
	$(IV) -o /dev/null -s s6_soc $(SOC_RTL)
	$(IV) -o /dev/null -s s6_top $(SOC_RTL) rtl/s6_top.v tb/s6_clkgen_sim.v
	@echo "lint ok (soc + fpga top elaborate; only PLL_BASE/BUFG need ISE)"

# =====================================================================
# Firmware
# =====================================================================
firmware: sw/hello.hex

sw/hello.hex: sw/hello.c sw/bsp.c sw/bsp.h sw/crt0.S sw/link.ld
	./sw/build.sh sw/hello.c

boot: sw/boot.hex

sw/boot.hex: sw/boot.c sw/bsp.c sw/bsp.h sw/crt0.S sw/link.ld
	./sw/build.sh sw/boot.c

# The same program linked at 0x800 so the bootloader can download it.
app: build/hello_app.bin

build/hello_app.bin: sw/hello.c sw/bsp.c sw/bsp.h sw/crt0.S sw/link_app.ld
	NAME=hello_app LDSCRIPT=sw/link_app.ld ./sw/build.sh sw/hello.c

# =====================================================================
# Synthesis (ISE 14.7 -- source its settings script first)
# =====================================================================
bit: sw/hello.hex
	./syn/build_ise.sh

bit-tcl: sw/hello.hex
	cd syn && xtclsh build.tcl

# Put the bootloader in the bitstream instead, and iterate over serial.
bit-boot: sw/boot.hex
	cp sw/boot.hex sw/firmware.hex
	@echo "sw/firmware.hex now holds the bootloader -- run: make bit"
	@echo "to go back to the plain firmware: git checkout -- sw/firmware.hex"

# =====================================================================
# Programming the board  (see docs/programming.md)
# =====================================================================
prog:
	$(OFL) -c ft2232 syn/s6_top.bit

prog-flash:
	$(OFL) -c ft2232 --fpga-part $(FPGA_PART) -f syn/s6_top.bit

upload: build/hello_app.bin
	$(PYTHON) tools/s6load.py -p $(PORT) build/hello_app.bin --term

term:
	$(PYTHON) tools/s6load.py -p $(PORT) --term

# =====================================================================
clean:
	rm -rf $(B)
	rm -f sw/*.hex
	rm -rf syn/xst syn/_ngo syn/*.ngc syn/*.ngd syn/*.ncd syn/*.pcf \
	       syn/*.bit syn/*.bin syn/*.bgn syn/*.drc syn/*.map syn/*.mrp \
	       syn/*.ngm syn/*.pad syn/*.par syn/*.ptwx syn/*.syr syn/*.twr \
	       syn/*.twx syn/*.unroutes syn/*.xpi syn/*.xrpt syn/*.lso \
	       syn/*.xise syn/*.gise syn/*_summary.xml syn/*.html syn/*.csv \
	       syn/netlist.lst syn/*.stx syn/iseconfig
