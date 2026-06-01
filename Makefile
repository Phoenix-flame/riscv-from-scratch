# =====================================================================
# Makefile  -  build & run the testbenches with Icarus Verilog
# Usage:  make alu | regfile | imem | dmem | immgen | control | cpu
#         make all      (run every testbench)
#         make wave-cpu (open the CPU waveform in GTKWave)
#         make clean
# =====================================================================
IV     = iverilog -g2012 -Wall
VVP    = vvp
B      = build

RTL_CORE = rtl/alu.v rtl/regfile.v rtl/imem.v rtl/dmem.v \
           rtl/immgen.v rtl/control.v rtl/cpu.v

.PHONY: all clean
all: alu regfile imem dmem immgen control cpu

alu:
	$(IV) -o $(B)/alu_tb.vvp rtl/alu.v tb/alu_tb.v && $(VVP) $(B)/alu_tb.vvp

regfile:
	$(IV) -o $(B)/regfile_tb.vvp rtl/regfile.v tb/regfile_tb.v && $(VVP) $(B)/regfile_tb.vvp

imem:
	$(IV) -o $(B)/imem_tb.vvp rtl/imem.v tb/imem_tb.v && $(VVP) $(B)/imem_tb.vvp

dmem:
	$(IV) -o $(B)/dmem_tb.vvp rtl/dmem.v tb/dmem_tb.v && $(VVP) $(B)/dmem_tb.vvp

immgen:
	$(IV) -o $(B)/immgen_tb.vvp rtl/immgen.v tb/immgen_tb.v && $(VVP) $(B)/immgen_tb.vvp

control:
	$(IV) -o $(B)/control_tb.vvp rtl/control.v tb/control_tb.v && $(VVP) $(B)/control_tb.vvp

cpu:
	$(IV) -o $(B)/cpu_tb.vvp $(RTL_CORE) tb/cpu_tb.v && $(VVP) $(B)/cpu_tb.vvp

# ---- assembled-program flow (Step 08) -------------------------------
# Assemble any sw/<name>.s into sw/<name>.hex
sw/%.hex: sw/%.s sw/bin2hex.py
	chmod +x sw/build.sh && ./sw/build.sh $<

sum: sw/sum.hex
	$(IV) -o $(B)/sum_tb.vvp $(RTL_CORE) tb/sum_tb.v && $(VVP) $(B)/sum_tb.vvp

# ---- C program flow (bonus: Step 10) --------------------------------
sw/cprog.hex: sw/sum.c sw/crt0.s sw/link.ld sw/bin2hex.py
	chmod +x sw/cbuild.sh && ./sw/cbuild.sh sw/sum.c

cprog: sw/cprog.hex
	$(IV) -o $(B)/c_tb.vvp $(RTL_CORE) tb/c_tb.v && $(VVP) $(B)/c_tb.vvp

wave-cpu:
	gtkwave $(B)/cpu_tb.vcd &

wave-sum:
	gtkwave $(B)/sum_tb.vcd $(B)/sum_tb.gtkw &

clean:
	rm -f $(B)/*.vvp $(B)/*.vcd
