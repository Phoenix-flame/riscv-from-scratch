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
$(shell mkdir -p $(B))            # ensure the build dir exists (works from a clean checkout)

RTL_CORE = rtl/alu.v rtl/regfile.v rtl/imem.v rtl/dmem.v \
           rtl/immgen.v rtl/control.v rtl/cpu.v

.PHONY: all clean run sim riscv-tests riscv-tests-all riscv-tests-fetch
all: alu regfile imem dmem immgen control cpu

# ---- rvsim: run any .bin/.hex/.elf and print CPU registers + state --
# Usage:  make run BIN=path/to/prog.bin            (single-cycle core)
#         make run BIN=sw/socdemo.hex CORE=soc DATA=sw/socdemo_data.hex
#         make run BIN=prog.elf ARGS="--trace --cycles 200 --mem 0:16"
# Or call the driver directly:  tools/rvsim <file> [options]   (see --help)
run:
	@test -n "$(BIN)" || { echo "usage: make run BIN=<file.bin|.hex|.elf> [CORE=cpu|soc] [DATA=img.hex] [ARGS=...]"; exit 1; }
	python3 tools/rvsim "$(BIN)" --core $(or $(CORE),cpu) $(if $(DATA),--data "$(DATA)") $(ARGS)

# ---- rvsim -i: interactive stepping debugger (step / break / regs / ...) --
# Usage:  make sim                                 (empty shell, then `load`)
#         make sim BIN=sw/sum.hex                  (load a program to step)
#         make sim BIN=sw/socdemo.hex CORE=soc DATA=sw/socdemo_data.hex
sim:
	python3 tools/rvsim -i $(if $(BIN),"$(BIN)") --core $(or $(CORE),cpu) $(if $(DATA),--data "$(DATA)") $(ARGS)

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

# ---- SoC with peripherals (Step 11) ---------------------------------
RTL_SOC = rtl/alu.v rtl/regfile.v rtl/imem.v rtl/dmem.v rtl/immgen.v \
          rtl/control.v rtl/csr.v rtl/uart.v rtl/timer.v rtl/syscon.v \
          rtl/cpu_core.v rtl/soc.v

sw/socdemo.hex: sw/soc_demo.c sw/firmware.c sw/firmware.h sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -nostdlib \
	  -nostartfiles -ffreestanding -fno-tree-loop-distribute-patterns -O1 \
	  -I sw -T sw/link.ld sw/crt0.s sw/soc_demo.c sw/firmware.c \
	  -o $(B)/socdemo.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/socdemo.elf $(B)/socdemo.bin
	python3 sw/bin2hex.py $(B)/socdemo.bin > sw/socdemo.hex
	@# RAM image: initialized data (.rodata/.data) at its link addresses
	riscv64-unknown-elf-objcopy -O verilog --verilog-data-width=1 \
	  --only-section=.rodata --only-section=.data --only-section=.sdata \
	  $(B)/socdemo.elf /dev/stdout 2>/dev/null | tr -d '\r' > sw/socdemo_data.hex

soc: sw/socdemo.hex
	$(IV) -o $(B)/soc_tb.vvp $(RTL_SOC) tb/soc_tb.v && $(VVP) $(B)/soc_tb.vvp

# ---- Timer interrupt demo (Step 15) ---------------------------------
sw/irqdemo.hex: sw/irq_demo.c sw/firmware.c sw/firmware.h sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32i_zicsr -mabi=ilp32 -nostdlib \
	  -nostartfiles -ffreestanding -fno-tree-loop-distribute-patterns -O1 \
	  -I sw -T sw/link.ld sw/crt0.s sw/irq_demo.c sw/firmware.c \
	  -o $(B)/irqdemo.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/irqdemo.elf $(B)/irqdemo.bin
	python3 sw/bin2hex.py $(B)/irqdemo.bin > sw/irqdemo.hex
	riscv64-unknown-elf-objcopy -O verilog --verilog-data-width=1 \
	  --only-section=.rodata --only-section=.data --only-section=.sdata \
	  $(B)/irqdemo.elf /dev/stdout 2>/dev/null | tr -d '\r' > sw/irqdemo_data.hex

irq: sw/irqdemo.hex
	$(IV) -o $(B)/irq_tb.vvp $(RTL_SOC) tb/irq_tb.v && $(VVP) $(B)/irq_tb.vvp

# ---- Illegal-instruction trap demo (Step 18) ------------------------
sw/ill.hex: sw/illegal_demo.c sw/firmware.c sw/firmware.h sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32i_zicsr -mabi=ilp32 -nostdlib \
	  -nostartfiles -ffreestanding -fno-tree-loop-distribute-patterns -O1 \
	  -I sw -T sw/link.ld sw/crt0.s sw/illegal_demo.c sw/firmware.c \
	  -o $(B)/ill.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/ill.elf $(B)/ill.bin
	python3 sw/bin2hex.py $(B)/ill.bin > sw/ill.hex
	riscv64-unknown-elf-objcopy -O verilog --verilog-data-width=1 \
	  --only-section=.rodata --only-section=.data --only-section=.sdata \
	  $(B)/ill.elf /dev/stdout 2>/dev/null | tr -d '\r' > sw/ill_data.hex

illegal: sw/ill.hex
	$(IV) -o $(B)/ill_tb.vvp $(RTL_SOC) tb/ill_tb.v && $(VVP) $(B)/ill_tb.vvp

# ---- RV32M demo (Step 16) -------------------------------------------
sw/md.hex: sw/muldiv_demo.c sw/firmware.c sw/firmware.h sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib \
	  -nostartfiles -ffreestanding -fno-tree-loop-distribute-patterns -O1 \
	  -I sw -T sw/link.ld sw/crt0.s sw/muldiv_demo.c sw/firmware.c \
	  -o $(B)/md.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/md.elf $(B)/md.bin
	python3 sw/bin2hex.py $(B)/md.bin > sw/md.hex
	riscv64-unknown-elf-objcopy -O verilog --verilog-data-width=1 \
	  --only-section=.rodata --only-section=.data --only-section=.sdata \
	  $(B)/md.elf /dev/stdout 2>/dev/null | tr -d '\r' > sw/md_data.hex

muldiv: sw/md.hex
	$(IV) -o $(B)/md_tb.vvp $(RTL_SOC) tb/md_tb.v && $(VVP) $(B)/md_tb.vvp

# ---- Pipelined core (Step 17) ---------------------------------------
RTL_PIPE = rtl/alu.v rtl/regfile.v rtl/imem.v rtl/dmem.v rtl/immgen.v \
           rtl/control.v rtl/cpu_pipe.v

pipe: sw/test_datapath.hex
	$(IV) -o $(B)/pipe_tb.vvp $(RTL_PIPE) tb/pipe_tb.v && $(VVP) $(B)/pipe_tb.vvp

pipe-sum: sw/sum.hex
	$(IV) -o $(B)/pipe_sum_tb.vvp $(RTL_PIPE) tb/pipe_sum_tb.v && $(VVP) $(B)/pipe_sum_tb.vvp

# ---- branch predictor: BTB + 2-bit counters vs predict-not-taken (Step 32) --
RTL_PIPE_BP = rtl/alu.v rtl/regfile.v rtl/imem.v rtl/dmem.v rtl/immgen.v \
              rtl/control.v rtl/cpu_pipe.v rtl/branch_predictor.v rtl/cpu_pipe_bp.v

sw/bpred_bench.hex: sw/bpred_bench.c sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles -ffreestanding \
	  -O1 -T sw/link.ld sw/crt0.s sw/bpred_bench.c -o $(B)/bpbench.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/bpbench.elf $(B)/bpbench.bin
	python3 sw/bin2hex.py $(B)/bpbench.bin > sw/bpred_bench.hex

bpred: sw/bpred_bench.hex ## compare predict-not-taken vs BTB+2-bit predictor (misprediction rate + speedup)
	$(IV) -o $(B)/bpred_tb.vvp $(RTL_PIPE_BP) tb/bpred_tb.v && $(VVP) $(B)/bpred_tb.vvp

# ---- ecall syscalls on the single-cycle core (Step 19) --------------
sw/ec.hex: sw/ecall_demo.c sw/trap_handler.S sw/firmware.c sw/firmware.h sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32i_zicsr -mabi=ilp32 -nostdlib \
	  -nostartfiles -ffreestanding -fno-tree-loop-distribute-patterns -O1 \
	  -I sw -T sw/link.ld sw/crt0.s sw/trap_handler.S sw/ecall_demo.c sw/firmware.c \
	  -o $(B)/ec.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/ec.elf $(B)/ec.bin
	python3 sw/bin2hex.py $(B)/ec.bin > sw/ec.hex
	riscv64-unknown-elf-objcopy -O verilog --verilog-data-width=1 \
	  --only-section=.rodata --only-section=.data --only-section=.sdata \
	  $(B)/ec.elf /dev/stdout 2>/dev/null | tr -d '\r' > sw/ec_data.hex

ecall: sw/ec.hex
	$(IV) -o $(B)/ecall_tb.vvp $(RTL_SOC) tb/ecall_tb.v && $(VVP) $(B)/ecall_tb.vvp

# ---- Machine/User privilege levels (Step 21) ------------------------
sw/pv.hex: sw/priv_demo.c sw/ptrap.S sw/firmware.c sw/firmware.h sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32i_zicsr -mabi=ilp32 -nostdlib \
	  -nostartfiles -ffreestanding -fno-tree-loop-distribute-patterns -O1 \
	  -I sw -T sw/link.ld sw/crt0.s sw/ptrap.S sw/priv_demo.c sw/firmware.c \
	  -o $(B)/pv.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/pv.elf $(B)/pv.bin
	python3 sw/bin2hex.py $(B)/pv.bin > sw/pv.hex
	riscv64-unknown-elf-objcopy -O verilog --verilog-data-width=1 \
	  --only-section=.rodata --only-section=.data --only-section=.sdata \
	  $(B)/pv.elf /dev/stdout 2>/dev/null | tr -d '\r' > sw/pv_data.hex

priv: sw/pv.hex
	$(IV) -o $(B)/priv_tb.vvp $(RTL_SOC) tb/priv_tb.v && $(VVP) $(B)/priv_tb.vvp

# ---- Sv32 virtual memory / MMU (Step 22) ----------------------------
RTL_MMU = rtl/alu.v rtl/regfile.v rtl/imem.v rtl/dmem.v rtl/immgen.v \
          rtl/control.v rtl/csr.v rtl/mmu.v rtl/uart.v rtl/timer.v \
          rtl/syscon.v rtl/cpu_core_mmu.v rtl/soc_mmu.v

sw/mm.hex: sw/mmu_demo.c sw/mtrap.S sw/firmware.c sw/firmware.h sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32i_zicsr -mabi=ilp32 -nostdlib \
	  -nostartfiles -ffreestanding -fno-tree-loop-distribute-patterns -O1 \
	  -I sw -T sw/link.ld sw/crt0.s sw/mtrap.S sw/mmu_demo.c sw/firmware.c \
	  -o $(B)/mm.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/mm.elf $(B)/mm.bin
	python3 sw/bin2hex.py $(B)/mm.bin > sw/mm.hex
	riscv64-unknown-elf-objcopy -O verilog --verilog-data-width=1 \
	  --only-section=.rodata --only-section=.data --only-section=.sdata \
	  $(B)/mm.elf /dev/stdout 2>/dev/null | tr -d '\r' > sw/mm_data.hex

mmu: sw/mm.hex
	$(IV) -o $(B)/mmu_tb.vvp $(RTL_MMU) tb/mmu_tb.v && $(VVP) $(B)/mmu_tb.vvp

# ---- Pipelined core WITH precise traps (Step 20) --------------------
RTL_SOCP = rtl/alu.v rtl/regfile.v rtl/imem.v rtl/dmem.v rtl/immgen.v \
           rtl/control.v rtl/csr.v rtl/uart.v rtl/timer.v rtl/syscon.v \
           rtl/cpu_pipe_trap.v rtl/soc_pipe.v

pipe-irq: sw/irqdemo.hex
	$(IV) -o $(B)/irq_pipe_tb.vvp $(RTL_SOCP) tb/irq_pipe_tb.v && $(VVP) $(B)/irq_pipe_tb.vvp

pipe-ecall: sw/ec.hex
	$(IV) -o $(B)/ecall_pipe_tb.vvp $(RTL_SOCP) tb/ecall_pipe_tb.v && $(VVP) $(B)/ecall_pipe_tb.vvp

pipe-illegal: sw/ill.hex
	$(IV) -o $(B)/ill_pipe_tb.vvp $(RTL_SOCP) tb/ill_pipe_tb.v && $(VVP) $(B)/ill_pipe_tb.vvp

# ---- Synthesizable FPGA top + real UART (Step 14) -------------------
RTL_FPGA = rtl/alu.v rtl/regfile.v rtl/imem.v rtl/dmem.v rtl/immgen.v \
           rtl/control.v rtl/csr.v rtl/timer.v rtl/uart_tx.v rtl/uart_hw.v \
           rtl/cpu_core.v rtl/fpga_top.v

uart_tx:
	$(IV) -o $(B)/uart_tx_tb.vvp rtl/uart_tx.v tb/uart_tx_tb.v && $(VVP) $(B)/uart_tx_tb.vvp

fpga: sw/socdemo.hex
	$(IV) -o $(B)/fpga_top_tb.vvp $(RTL_FPGA) tb/fpga_top_tb.v && $(VVP) $(B)/fpga_top_tb.vvp

wave-cpu:
	gtkwave $(B)/cpu_tb.vcd &

wave-sum:
	gtkwave $(B)/sum_tb.vcd tb/sum_tb.gtkw &

clean:
	rm -f $(B)/*.vvp $(B)/*.vcd
	rm -rf $(B)/rvtests

# ---- Synthesizable BRAM SoC for Zynq-7010 (Step 23) -----------------
RTL_FPGA_FULL = rtl/alu.v rtl/regfile.v rtl/immgen.v rtl/control.v rtl/csr.v \
                rtl/timer.v rtl/uart_tx.v rtl/uart_hw.v rtl/bram_rom.v \
                rtl/bram_ram.v rtl/cpu_mc.v rtl/soc_fpga.v

sw/fp.hex: sw/fpga_demo.c sw/firmware.h sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles \
	  -ffreestanding -O1 -I sw -T sw/link.ld sw/crt0.s sw/fpga_demo.c \
	  -o $(B)/fp.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/fp.elf $(B)/fp.bin
	python3 sw/bin2hex.py $(B)/fp.bin > sw/fp.hex

fpga-full: sw/fp.hex
	$(IV) -o $(B)/fpga_full_tb.vvp $(RTL_FPGA_FULL) tb/fpga_full_tb.v && $(VVP) $(B)/fpga_full_tb.vvp

# ---- Synthesizable MMU on hardware (multi-cycle Sv32 walker, BRAM PTs) -
RTL_FPGA_MMU = rtl/alu.v rtl/regfile.v rtl/immgen.v rtl/control.v rtl/csr.v \
               rtl/timer.v rtl/uart_tx.v rtl/uart_hw.v rtl/bram_rom.v \
               rtl/bram_ram.v rtl/cpu_mc_mmu.v rtl/soc_fpga_mmu.v

sw/mh.hex: sw/mmu_hw_demo.c sw/mmu_htrap.S sw/firmware.h sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32im_zicsr -mabi=ilp32 -nostdlib -nostartfiles \
	  -ffreestanding -O1 -I sw -T sw/link.ld sw/crt0.s sw/mmu_htrap.S sw/mmu_hw_demo.c \
	  -o $(B)/mh.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/mh.elf $(B)/mh.bin
	python3 sw/bin2hex.py $(B)/mh.bin > sw/mh.hex

mmu-hw: sw/mh.hex
	$(IV) -o $(B)/mmu_hw_tb.vvp $(RTL_FPGA_MMU) tb/mmu_hw_tb.v && $(VVP) $(B)/mmu_hw_tb.vvp

# ---- Step 41: translated instruction fetch + I/D TLBs ------------------
RTL_FPGA_TLB = rtl/alu.v rtl/regfile.v rtl/immgen.v rtl/control.v rtl/csr.v \
               rtl/timer.v rtl/uart_tx.v rtl/uart_hw.v rtl/bram_rom.v \
               rtl/bram_ram.v rtl/tlb.v rtl/cpu_mc_tlb.v rtl/soc_fpga_tlb.v

sw/tlb.hex: sw/tlb_demo.c sw/tlb_asm.S sw/crt0.s sw/link_tlb.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32im_zicsr -mabi=ilp32 -nostdlib -nostartfiles \
	  -ffreestanding -O1 -I sw -T sw/link_tlb.ld sw/crt0.s sw/tlb_asm.S sw/tlb_demo.c \
	  -o $(B)/tlb.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/tlb.elf $(B)/tlb.bin
	python3 sw/bin2hex.py $(B)/tlb.bin > sw/tlb.hex

tlb: sw/tlb.hex ## translated fetch + I/D TLBs + sfence.vma, vs a walk-every-access core
	$(IV) -o $(B)/tlb_tb.vvp $(RTL_FPGA_TLB) tb/tlb_tb.v && $(VVP) $(B)/tlb_tb.vvp

# ---- Step 42: the unified pipeline (RV32IMA + M/U + Sv32 + TLBs) ------
RTL_PIPE_U = rtl/alu.v rtl/regfile.v rtl/immgen.v rtl/control.v rtl/csr_s.v rtl/branch_predictor.v \
             rtl/timer.v rtl/uart_tx.v rtl/uart_hw.v rtl/tlb.v rtl/ptw.v rtl/zb_unit.v rtl/vec_unit.v \
             rtl/cpu_pipe_u.v rtl/soc_pipe_u.v

# Step 38's scheduler with the code page mapped X and sfence.vma on each switch
sw/smmu_vm.hex: sw/sched_mmu.c sw/sched_mmu_asm.S sw/firmware.h sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32im_zicsr -mabi=ilp32 -nostdlib -nostartfiles \
	  -ffreestanding -O1 -DSCHED_VM -I sw -T sw/link.ld sw/crt0.s sw/sched_mmu_asm.S sw/sched_mmu.c \
	  -o $(B)/smmu_vm.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/smmu_vm.elf $(B)/smmu_vm.bin
	python3 sw/bin2hex.py $(B)/smmu_vm.bin > sw/smmu_vm.hex

pipe-u: sw/tlb.hex sw/at.hex sw/smmu_vm.hex ## unified pipeline: TLB demo + atomics + isolated processes + riscv-tests (M and U/Sv32)
	$(IV) -o $(B)/pipe_u_tlb_tb.vvp $(RTL_PIPE_U) tb/pipe_u_tlb_tb.v && $(VVP) $(B)/pipe_u_tlb_tb.vvp
	$(IV) -o $(B)/pipe_u_prog_tb.vvp $(RTL_PIPE_U) tb/pipe_u_prog_tb.v && \
	  $(VVP) $(B)/pipe_u_prog_tb.vvp +ROM=sw/at.hex +RAM=sw/at.hex +EXPECT=tb/atomic_expected.txt
	$(IV) -o $(B)/pipe_u_sched_tb.vvp $(RTL_PIPE_U) tb/pipe_u_sched_tb.v && $(VVP) $(B)/pipe_u_sched_tb.vvp
	python3 tools/rvtests --core pipe_u
	python3 tools/rvtests --core pipe_u_vm

# the same programs (and pipe-u-sv's paging and S-mode ones) on the Linux
# board's core: every Step 57-58 option on, through soc_pipe_u (Step 58)
pipe-u-board: sw/tlb.hex sw/at.hex sw/smmu_vm.hex sw/sv.hex sw/smode.hex ## pipe-u + pipe-u-sv programs on the board's core
	$(IV) -DPIPE_U_BOARD -o $(B)/pipe_u_tlb_brd.vvp $(RTL_PIPE_U) tb/pipe_u_tlb_tb.v && $(VVP) $(B)/pipe_u_tlb_brd.vvp
	$(IV) -DPIPE_U_BOARD -o $(B)/pipe_u_prog_brd.vvp $(RTL_PIPE_U) tb/pipe_u_prog_tb.v && \
	  $(VVP) $(B)/pipe_u_prog_brd.vvp +ROM=sw/at.hex +RAM=sw/at.hex +EXPECT=tb/atomic_expected.txt
	$(IV) -DPIPE_U_BOARD -o $(B)/pipe_u_sched_brd.vvp $(RTL_PIPE_U) tb/pipe_u_sched_tb.v && $(VVP) $(B)/pipe_u_sched_brd.vvp
	$(IV) -DPIPE_U_BOARD -o $(B)/pipe_u_sv_brd.vvp $(RTL_PIPE_U) tb/pipe_u_sv_tb.v && $(VVP) $(B)/pipe_u_sv_brd.vvp
	$(IV) -DPIPE_U_BOARD -o $(B)/pipe_u_smode_brd.vvp $(RTL_PIPE_U) tb/pipe_u_smode_tb.v && $(VVP) $(B)/pipe_u_smode_brd.vvp

# ---- Step 43: I-cache / D-cache in front of slow (DDR-like) memory -----
RTL_PIPE_C = rtl/alu.v rtl/regfile.v rtl/immgen.v rtl/control.v rtl/csr_s.v rtl/branch_predictor.v \
             rtl/timer.v rtl/uart_tx.v rtl/uart_hw.v rtl/tlb.v rtl/ptw.v rtl/zb_unit.v rtl/vec_unit.v \
             rtl/cpu_pipe_u.v rtl/mem_slow.v rtl/icache.v rtl/dcache.v \
             rtl/mem_bridge.v rtl/soc_pipe_c.v

sw/cb.hex: sw/cache_bench.c sw/firmware.c sw/firmware.h sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32im_zicsr -mabi=ilp32 -nostdlib -nostartfiles \
	  -ffreestanding -O1 -I sw -T sw/link.ld sw/crt0.s sw/firmware.c sw/cache_bench.c \
	  -o $(B)/cb.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/cb.elf $(B)/cb.bin
	python3 sw/bin2hex.py $(B)/cb.bin > sw/cb.hex

CACHE_LATS ?= 1 5 10 20 40
cache-unit: ## D-caches vs a reference model (and Step 59's block-RAM I-cache vs memory): random accesses, evictions, slow memory
	$(IV) -o $(B)/dcache_tb.vvp rtl/mem_slow.v rtl/dcache.v tb/dcache_tb.v && $(VVP) $(B)/dcache_tb.vvp
	$(IV) -o $(B)/dcache_b_tb.vvp rtl/mem_slow.v rtl/dcache.v tb/dcache_b_tb.v && $(VVP) $(B)/dcache_b_tb.vvp
	$(IV) -o $(B)/icache_b_tb.vvp rtl/mem_slow.v rtl/icache.v tb/icache_b_tb.v && $(VVP) $(B)/icache_b_tb.vvp

cache: sw/cb.hex sw/tlb.hex sw/smmu_vm.hex sw/sv.hex ## I/D caches vs no caches on slow memory, across latencies; + MMU programs and riscv-tests through the caches
	@for L in $(CACHE_LATS); do \
	  $(IV) -Pcache_tb.LAT=$$L -o $(B)/cache_tb_$$L.vvp $(RTL_PIPE_C) rtl/soc_pipe_u.v tb/cache_tb.v && \
	  $(VVP) $(B)/cache_tb_$$L.vvp | grep -v '\$$finish' || exit 1; done
	$(IV) -o $(B)/cache_sys_tb.vvp $(RTL_PIPE_C) tb/cache_sys_tb.v && $(VVP) $(B)/cache_sys_tb.vvp
	python3 tools/rvtests --core pipe_c
	python3 tools/rvtests --core pipe_c_vm

# ---- Step 44: S-mode + branch predictor folded into the unified pipeline -
sw/sv.hex: sw/sv_demo.c sw/sv_asm.S sw/crt0.s sw/link_tlb.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32ima_zicsr -mabi=ilp32 -nostdlib -nostartfiles \
	  -ffreestanding -O1 -I sw -T sw/link_tlb.ld sw/crt0.s sw/sv_asm.S sw/sv_demo.c \
	  -o $(B)/sv.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/sv.elf $(B)/sv.bin
	python3 sw/bin2hex.py $(B)/sv.bin > sw/sv.hex

pipe-u-sv: sw/sv.hex sw/smode.hex sw/bpred_bench.hex sw/cb.hex ## unified pipeline: S-mode kernel with paging, Step 39 delegation demo, branch predictor on/off
	$(IV) -o $(B)/pipe_u_sv_tb.vvp $(RTL_PIPE_U) tb/pipe_u_sv_tb.v && $(VVP) $(B)/pipe_u_sv_tb.vvp
	$(IV) -o $(B)/pipe_u_smode_tb.vvp $(RTL_PIPE_U) tb/pipe_u_smode_tb.v && $(VVP) $(B)/pipe_u_smode_tb.vvp
	$(IV) -o $(B)/pipe_u_bp_tb.vvp $(RTL_PIPE_U) tb/pipe_u_bp_tb.v && $(VVP) $(B)/pipe_u_bp_tb.vvp

# ---- Step 47: the vector unit (Zve32x) ----------------------------------
sw/vec_vm.hex: sw/vec_vm.S tools/vtest/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32ima_zicsr_zve32x -mabi=ilp32 -nostdlib -nostartfiles \
	  -T tools/vtest/link.ld sw/vec_vm.S -o $(B)/vec_vm.elf
	riscv64-unknown-elf-objcopy -O binary $(B)/vec_vm.elf $(B)/vec_vm.bin
	python3 sw/bin2hex.py $(B)/vec_vm.bin > sw/vec_vm.hex

sw/vec_bench.hex: sw/vec_bench.c sw/firmware.c sw/firmware.h sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32ima_zicsr_zve32x -mabi=ilp32 -nostdlib -nostartfiles \
	  -ffreestanding -O2 -fno-tree-vectorize -I sw -T sw/link.ld sw/crt0.s sw/firmware.c \
	  sw/vec_bench.c -o $(B)/vec_bench.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/vec_bench.elf $(B)/vec_bench.bin
	python3 sw/bin2hex.py $(B)/vec_bench.bin > sw/vec_bench.hex

VTEST_SEEDS ?= 0-199
vec: sw/vec_vm.hex sw/vec_bench.hex ## vector unit: random differential test vs an RVV model (VLEN 64/128/256, caches), faults under Sv32, benchmark
	python3 tools/vtest/run.py --seeds $(VTEST_SEEDS) --count 100
	python3 tools/vtest/run.py --seeds 0-49 --count 100 --vlen 64
	python3 tools/vtest/run.py --seeds 0-49 --count 100 --vlen 256
	python3 tools/vtest/run.py --seeds 0-49 --count 100 --cached
	$(IV) -o $(B)/pipe_u_prog_tb.vvp $(RTL_PIPE_U) tb/pipe_u_prog_tb.v
	$(VVP) $(B)/pipe_u_prog_tb.vvp +ROM=sw/vec_vm.hex +RAM=sw/vec_vm.hex +EXPECT=tb/vec_vm_expected.txt | grep -v '\$$finish' | tee $(B)/vec_vm.log
	@grep -q 'PIPE-U PROG: PASS' $(B)/vec_vm.log
	$(VVP) $(B)/pipe_u_prog_tb.vvp +ROM=sw/vec_bench.hex +RAM=sw/vec_bench.hex | grep -v '\$$finish' | tee $(B)/vec_bench.log
	@grep -q 'VEC-BENCH: PASS' $(B)/vec_bench.log

# ---- Step 48: performance counters, Dhrystone and CoreMark --------------
# make bench-counters      directed checks of cycle/instret/event counters (Icarus)
# make bench               the full Dhrystone + CoreMark matrix (tools/bench)
# make bench-quick         headline configuration only, short CoreMark run
# tools/bench builds with Verilator when it is installed (~1M cycles/s) and
# falls back to Icarus (~7k cycles/s); ARGS="--sim iverilog" forces it.
sw/cnt_test.hex: sw/bench/cnt_test.c sw/firmware.c sw/firmware.h sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32im_zicsr_zicntr_zihpm -mabi=ilp32 -nostdlib -nostartfiles \
	  -ffreestanding -O1 -I sw -T sw/link.ld sw/crt0.s sw/firmware.c sw/bench/cnt_test.c \
	  -o $(B)/cnt_test.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/cnt_test.elf $(B)/cnt_test.bin
	python3 sw/bin2hex.py $(B)/cnt_test.bin > sw/cnt_test.hex

.PHONY: bench bench-quick bench-counters
bench-counters: sw/cnt_test.hex ## counters: exact cycle/instret/event deltas, M-mode writes, read-only alias traps
	$(IV) -o $(B)/pipe_u_prog_tb.vvp $(RTL_PIPE_U) tb/pipe_u_prog_tb.v
	$(VVP) $(B)/pipe_u_prog_tb.vvp +ROM=sw/cnt_test.hex +RAM=sw/cnt_test.hex +EXPECT=tb/cnt_expected.txt | grep -v '\$$finish' | tee $(B)/cnt_test.log
	@grep -q 'PIPE-U PROG: PASS' $(B)/cnt_test.log

bench: bench-counters ## Dhrystone + CoreMark: DMIPS/MHz and CoreMark/MHz across compiler builds and memory systems
	python3 tools/bench $(ARGS)

bench-quick: bench-counters ## Dhrystone + CoreMark, headline configuration only (short CoreMark run)
	python3 tools/bench --quick $(ARGS)

# ---- Step 49: boot ROM + device tree + SBI on a virt-style platform --------
# make uart16550       register-level test of the ns16550a UART (Icarus)
# make plic-sifive     register-level test of the standard PLIC (Step 50)
# make axi4-line       the AXI4 line master against a stalling slave (Step 51)
# make boot-board      the board configuration in simulation (Step 51)
# make boot-synth      Yosys synthesis of fpga_top_boot for the Zynq-7010
# make boot            the system test: the ROM rejects two bad images, then
#                      loads and runs four programs over the UART in a row
#                      (tools/rvboot; Verilator when installed, else Icarus)
# tools/rvboot image prog.elf -o prog.rvbi --bootargs "..."   your own image
# Needs dtc (device-tree-compiler) for the DTB.
BB = $(B)/boot
$(shell mkdir -p $(BB))
RTL_UART16550 = rtl/uart_tx_cfg.v rtl/uart_rx.v rtl/uart16550.v
BOOT_CC  = riscv64-unknown-elf-gcc -march=rv32ima_zicsr_zifencei_zicntr -mabi=ilp32 -Os -g \
           -ffreestanding -nostdlib -nostartfiles -fno-tree-loop-distribute-patterns \
           -ffunction-sections -Wl,--gc-sections -Wl,--no-warn-rwx-segments \
           -Wall -Wextra -I sw/boot
BOOT_LIB = sw/boot/fdt.c sw/boot/lib.c sw/boot/ns16550.c
BOOT_HDR = sw/boot/fdt.h sw/boot/lib.h sw/boot/ns16550.h sw/boot/sbi.h sw/boot/platform.h

$(BB)/rvfs-soc.dtb: sw/boot/rvfs-soc.dts sw/boot/platform.h
	cpp -nostdinc -undef -x assembler-with-cpp -I sw/boot $< | dtc -q -I dts -O dtb -o $@ -

$(BB)/rom.hex: sw/boot/rom_start.S sw/boot/rom_main.c sw/boot/rom_sbi.c sw/boot/rom.h sw/boot/rom.ld \
               sw/boot/bootimg.h $(BOOT_LIB) $(BOOT_HDR) $(BB)/rvfs-soc.dtb sw/bin2hex.py
	$(BOOT_CC) -DDTB_PATH='"$(BB)/rvfs-soc.dtb"' -T sw/boot/rom.ld sw/boot/rom_start.S \
	  sw/boot/rom_main.c sw/boot/rom_sbi.c $(BOOT_LIB) -lgcc -o $(BB)/rom.elf
	riscv64-unknown-elf-objcopy -O binary $(BB)/rom.elf $(BB)/rom.bin
	python3 sw/bin2hex.py $(BB)/rom.bin > $@

$(BB)/dtdemo.elf: sw/boot/dtdemo.c sw/boot/payload_start.S sw/boot/payload.ld $(BOOT_LIB) $(BOOT_HDR)
	$(BOOT_CC) -T sw/boot/payload.ld sw/boot/payload_start.S sw/boot/dtdemo.c $(BOOT_LIB) -lgcc -o $@

$(BB)/kdemo.elf: sw/boot/kdemo.c sw/boot/payload_start.S sw/boot/payload.ld $(BOOT_LIB) $(BOOT_HDR)
	$(BOOT_CC) -T sw/boot/payload.ld sw/boot/payload_start.S sw/boot/kdemo.c $(BOOT_LIB) -lgcc -o $@

$(BB)/mhello.elf: sw/boot/mhello.c sw/boot/payload_start.S sw/boot/payload.ld $(BOOT_LIB) $(BOOT_HDR)
	$(BOOT_CC) -T sw/boot/payload.ld sw/boot/payload_start.S sw/boot/mhello.c $(BOOT_LIB) -lgcc -o $@

# Step 37's libc_demo.c, unchanged, on picolibc retargeted to the SBI; the
# integer-only printf (__i_vfprintf) keeps it at ~4 KB instead of ~13 KB
$(BB)/libc_demo.elf: sw/libc_demo.c sw/boot/sbi_libc.c sw/boot/sbi.h sw/boot/payload_start.S sw/boot/payload.ld
	riscv64-unknown-elf-gcc -march=rv32im_zicsr -mabi=ilp32 -nostdlib -nostartfiles -ffreestanding -Os \
	  -isystem $(PICOLIBC_INC) -I sw/boot -T sw/boot/payload.ld -Wl,--no-warn-rwx-segments \
	  sw/boot/payload_start.S sw/boot/sbi_libc.c sw/libc_demo.c \
	  -L $(PICOLIBC_LIB) -Wl,--defsym=vfprintf=__i_vfprintf -Wl,-u,__i_vfprintf -lc -lgcc -o $@

# The board build (Step 51): the same ROM and DT for 115200 baud from the
# 50 MHz PL oscillator (UART divisor 27), and fpga_top_boot around them.
BBB = $(BB)/board
$(shell mkdir -p $(BBB))
$(BBB)/rvfs-soc.dtb: sw/boot/rvfs-soc.dts sw/boot/platform.h
	cpp -nostdinc -undef -x assembler-with-cpp -DUART_DIVISOR=27 -I sw/boot $< | dtc -q -I dts -O dtb -o $@ -

$(BBB)/rom.hex: sw/boot/rom_start.S sw/boot/rom_main.c sw/boot/rom_sbi.c sw/boot/rom.h sw/boot/rom.ld \
               sw/boot/bootimg.h $(BOOT_LIB) $(BOOT_HDR) $(BBB)/rvfs-soc.dtb sw/bin2hex.py
	$(BOOT_CC) -DUART_DIVISOR=27 -DDTB_PATH='"$(BBB)/rvfs-soc.dtb"' -T sw/boot/rom.ld sw/boot/rom_start.S \
	  sw/boot/rom_main.c sw/boot/rom_sbi.c $(BOOT_LIB) -lgcc -o $(BBB)/rom.elf
	riscv64-unknown-elf-objcopy -O binary $(BBB)/rom.elf $(BBB)/rom.bin
	python3 sw/bin2hex.py $(BBB)/rom.bin > $@

# The Linux board build (Steps 57, 58): fpga_top_linux runs on the PS's FCLK1
# at IO PLL / 20 = 50 MHz (divisor 27 is 115200 baud within 0.5 %) and has no
# Zba/Zbb/Zbc/Zbs, so its ROM and DT say both. (fpga_top_boot keeps $(BBB).)
BBL = $(BB)/linux-board
BBL_DEFS = -DPLAT_CLOCK_HZ=50000000 -DUART_DIVISOR=27 -DPLAT_NO_ZB
$(shell mkdir -p $(BBL))
$(BBL)/rvfs-soc.dtb: sw/boot/rvfs-soc.dts sw/boot/platform.h
	cpp -nostdinc -undef -x assembler-with-cpp $(BBL_DEFS) -I sw/boot $< | dtc -q -I dts -O dtb -o $@ -

$(BBL)/rom.hex: sw/boot/rom_start.S sw/boot/rom_main.c sw/boot/rom_sbi.c sw/boot/rom.h sw/boot/rom.ld \
               sw/boot/bootimg.h $(BOOT_LIB) $(BOOT_HDR) $(BBL)/rvfs-soc.dtb sw/bin2hex.py
	$(BOOT_CC) $(BBL_DEFS) -DDTB_PATH='"$(BBL)/rvfs-soc.dtb"' -T sw/boot/rom.ld sw/boot/rom_start.S \
	  sw/boot/rom_main.c sw/boot/rom_sbi.c $(BOOT_LIB) -lgcc -o $(BBL)/rom.elf
	riscv64-unknown-elf-objcopy -O binary $(BBL)/rom.elf $(BBL)/rom.bin
	python3 sw/bin2hex.py $(BBL)/rom.bin > $@

RTL_BOOT = rtl/alu.v rtl/regfile.v rtl/immgen.v rtl/control.v rtl/csr_s.v rtl/branch_predictor.v \
           rtl/tlb.v rtl/ptw.v rtl/zb_unit.v rtl/vec_unit.v rtl/cpu_pipe_u.v rtl/uart_tx_cfg.v \
           rtl/uart_rx.v rtl/uart16550.v rtl/clint_sifive.v rtl/plic_sifive.v rtl/icache.v \
           rtl/dcache.v rtl/line_arb.v rtl/oz/oz_burst_mem.v rtl/axi4_line_master.v rtl/soc_boot.v

.PHONY: uart16550 plic-sifive axi4-line boot boot-sw boot-board boot-synth
uart16550: ## ns16550a UART: divisor, framing, FIFOs, overrun, errors, interrupts, loopback
	$(IV) -o $(B)/uart16550_tb.vvp $(RTL_UART16550) tb/uart16550_tb.v && $(VVP) $(B)/uart16550_tb.vvp | grep -v '\$$finish'

plic-sifive: ## standard-layout PLIC (Step 50): M + S contexts, enables, thresholds, claim/complete
	$(IV) -o $(B)/plic_sifive_tb.vvp rtl/plic_sifive.v tb/plic_sifive_tb.v && $(VVP) $(B)/plic_sifive_tb.vvp | grep -v '\$$finish'

axi4-line: ## AXI4 burst master (Steps 51, 54): cache lines vs a stalling AXI slave, 32- and 64-bit (HP0), error responses, protocol checks
	$(IV) -o $(B)/axi4_line_tb.vvp rtl/axi4_line_master.v tb/axi4_mem.v tb/axi4_line_tb.v && $(VVP) $(B)/axi4_line_tb.vvp | grep -v '\$$finish'
	$(IV) -P axi4_line_tb.DATA_W=64 -o $(B)/axi4_line_tb64.vvp rtl/axi4_line_master.v tb/axi4_mem.v tb/axi4_line_tb.v && $(VVP) $(B)/axi4_line_tb64.vvp | grep -v '\$$finish'

boot-sw: $(BB)/rom.hex $(BB)/dtdemo.elf $(BB)/kdemo.elf $(BB)/mhello.elf $(BB)/libc_demo.elf

boot: boot-sw ## boot ROM + DT + SBI + PLIC/faults/Svade, on ideal memory, caches + BRAM, and caches + DDR (AXI4)
	python3 tools/rvboot test $(ARGS)

boot-board: boot-sw $(BBB)/rom.hex $(BBL)/rom.hex ## the board builds in simulation (115200 baud; 128 KiB BRAM, and 64 MiB of DDR over HP0): banner, a bad image, libc_demo
	python3 tools/rvboot test --memsys board $(ARGS)
	python3 tools/rvboot test --memsys board-ddr $(ARGS)

boot-synth: $(BBB)/rom.hex ## Yosys: fpga_top_boot for the Zynq-7010 (LUTs, FFs, block RAMs)
	yosys -q -p "read_verilog $(RTL_BOOT) rtl/fpga_top_boot.v; synth_xilinx -flatten -abc9 -arch xc7 -top fpga_top_boot; tee -o $(BBB)/synth.txt stat"
	@grep -E "LUT[1-6]|FD[RSCE]|RAMB|CARRY4|RAM32|RAM64" $(BBB)/synth.txt

# ---- Step 53: Linux from source on the boot platform -------------------
# make linux         fetch (third_party/, pinned + hash-checked), build musl,
#                    busybox, an initramfs and Linux 6.18 (build/linux/), boot
#                    it on soc_boot with 64 MiB of DDR, type at its shell and
#                    check the transcript (tools/rvlinux; ~2 GB of sources,
#                    ~15 min: the kernel goes over the serial line)
# make linux-fast    the same, but the bench preloads the kernel (~5 min)
.PHONY: linux linux-fast
linux: boot-sw ## Linux 6.18 + busybox from source, booted on soc_boot (DDR) over the serial port; checks its shell (~15 min)
	python3 tools/rvlinux all $(ARGS)

linux-fast: boot-sw ## ... the same with the kernel preloaded into the DDR model instead of sent (~5 min)
	python3 tools/rvlinux all --fast $(ARGS)

# ---- Step 54: Linux on the Mitra-7010, its RAM in PS DDR over S_AXI_HP0 ---
# make linux-board          Linux on the board's configuration, in simulation:
#                           the board ROM, 115200 baud, 64 MiB over a 64-bit
#                           HP0-shaped port (the kernel preloaded)
# make linux-oz OZ=<dir>    write projects/riscv_linux into an OpenZynq checkout
#                           (rtl/fpga_top_linux.v on its ps7_gp0 with HP0, pins,
#                           the PS program, a testbench), build the board's
#                           kernel image, and simulate that top (verilator)
.PHONY: linux-board linux-oz
linux-board: boot-sw $(BBB)/rom.hex $(BBL)/rom.hex ## Linux on the board configuration (board ROM, 115200, 64-bit HP0 port), simulated
	python3 tools/rvlinux all --board $(ARGS)

linux-oz: boot-sw $(BBB)/rom.hex $(BBL)/rom.hex ## export the Linux board project into OpenZynq (OZ=...) and simulate its top on OZ's ps7_gp0
	@test -n "$(OZ)" || { echo "usage: make linux-oz OZ=/path/to/OpenZynq"; exit 1; }
	python3 tools/rvlinux oz-export $(OZ) $(ARGS)
	python3 tools/rvlinux oz-sim $(OZ)

# ---- Step 55: U-Boot in front of Linux --------------------------------
# make uboot          fetch (pinned, hash-checked) + build U-Boot v2024.10 for
#                     soc_boot, a sim and a board build, and the images: U-Boot
#                     alone, and U-Boot + Linux in one image (build/linux/)
# make linux-uboot    U-Boot boots, autoboots Linux with booti, the shell is
#                     checked as in make linux (kernel and U-Boot preloaded)
.PHONY: uboot linux-uboot
uboot: ## fetch + build U-Boot for soc_boot (sim + board builds) and the U-Boot(+Linux) boot images
	python3 tools/rvlinux uboot $(ARGS)

linux-uboot: boot-sw ## U-Boot boots Linux (booti) on soc_boot (DDR), then the shell checks of make linux
	python3 tools/rvlinux run --fast --uboot $(ARGS)

# ---- Step 56: booting with no PC: flash -> the PS -> DDR -> the ROM ------
# make boot-mem       the ROM boots an image it finds in memory, refuses a
#                     corrupt one, and gives the serial prompt on a key
# make ps-test        the PS program's BOOT.BIN parser and QSPI flash writer,
#                     on this PC against a model of the controller and flash
# make linux-frommem  U-Boot + Linux as the board boots from flash: the image
#                     at 0x8300_0000, nothing sent, the board configuration
.PHONY: boot-mem ps-test linux-frommem
boot-mem: boot-sw ## the ROM boots an RVBI image left in RAM (as the PS leaves one from flash); bad image and key-press fallbacks
	python3 tools/rvboot test-bootmem $(ARGS)

ps-test: ## the PS program's BOOT.BIN parser + QSPI writer against a controller/flash model (host C)
	$(MAKE) -C sw/linux/board/ps test

linux-frommem: boot-sw $(BBB)/rom.hex $(BBL)/rom.hex ## U-Boot + Linux booted from memory, as from flash on the board (board configuration), shell checks
	python3 tools/rvlinux run --frommem --uboot --board $(ARGS)

# ---- Step 57: a divider that fits ---------------------------------------
# make div-iter       the 32-cycle divider (DIV_ITER) against the array divider
#                     on corners and 4000 random operand pairs, plus the abort
#                     and freeze cases
# make riscv-tests CORE=pipe_u_div / pipe_c_uni_div     rv32um through the pipeline with it
.PHONY: div-iter mul-2c
div-iter: ## Step 57: the iterative RV32M divider vs the array divider (corners + random; abort, hold, freeze)
	$(IV) -o $(B)/div_iter_tb.vvp rtl/alu.v tb/div_iter_tb.v && $(VVP) $(B)/div_iter_tb.vvp | grep -v '\$$finish'

mul-2c: ## Step 58: the registered multiplier vs the ALU's products (corners + random; abort, hold, freeze)
	$(IV) -o $(B)/mul_2c_tb.vvp rtl/alu.v tb/mul_2c_tb.v && $(VVP) $(B)/mul_2c_tb.vvp | grep -v '\$$finish'

# ---- Step 45: menuconfig -> a generated RISC-V project for OpenZynq ------
# make menuconfig                         edit .config (curses menu, Kconfig)
# make defconfig DEFCONFIG=configs/...    start from a preset
# make savedefconfig                      write the minimal form to ./defconfig
# make rvgen                              .config -> build/oz/projects/<name>/, simulated
# make oz-export OZ=../OpenZynq           ... and copy it into an OpenZynq checkout
# make rvgen-all                          every configs/oz_*_defconfig, generated + simulated
KCONFIG_CONFIG ?= .config
export KCONFIG_CONFIG
DEFCONFIG ?= configs/oz_full_defconfig
.PHONY: menuconfig defconfig savedefconfig olddefconfig rvgen oz-export rvgen-all
menuconfig: ## edit the RISC-V configuration for OpenZynq (writes .config)
	python3 tools/kconfig/menuconfig.py Kconfig
defconfig: ## load a preset: make defconfig DEFCONFIG=configs/oz_mc_defconfig
	python3 tools/kconfig/defconfig.py --kconfig Kconfig $(DEFCONFIG)
savedefconfig:
	python3 tools/kconfig/savedefconfig.py --kconfig Kconfig --out defconfig
olddefconfig:
	python3 tools/kconfig/olddefconfig.py Kconfig
rvgen: ## generate (and simulate) the OpenZynq project for .config
	python3 tools/rvgen/rvgen.py --config $(KCONFIG_CONFIG) --sim
oz-export: ## ... and copy it into an OpenZynq checkout: make oz-export OZ=../OpenZynq
	@test -n "$(OZ)" || { echo "usage: make oz-export OZ=/path/to/OpenZynq"; exit 1; }
	python3 tools/rvgen/rvgen.py --config $(KCONFIG_CONFIG) --sim --oz $(OZ)
rvgen-all: ## generate + simulate every configs/oz_*_defconfig
	@fail=0; for c in configs/oz_*_defconfig; do \
	  echo "=== $$c"; \
	  python3 tools/rvgen/rvgen.py --config $$c --sim > $(B)/rvgen_$$(basename $$c).log 2>&1 \
	    && grep -E '^rvgen: rv32|^PASS:' $(B)/rvgen_$$(basename $$c).log \
	    || { fail=1; tail -30 $(B)/rvgen_$$(basename $$c).log; }; \
	done; exit $$fail

# ---- Preemptive multitasking (two tasks, timer-driven scheduler) ------
RTL_SOC = rtl/alu.v rtl/regfile.v rtl/immgen.v rtl/control.v rtl/csr.v rtl/imem.v \
          rtl/dmem.v rtl/uart.v rtl/timer.v rtl/syscon.v rtl/cpu_core.v rtl/soc.v

sw/sch.hex: sw/sched.c sw/sched_asm.S sw/firmware.h sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32i_zicsr -mabi=ilp32 -nostdlib -nostartfiles \
	  -ffreestanding -O1 -I sw -T sw/link.ld sw/crt0.s sw/sched_asm.S sw/sched.c \
	  -o $(B)/sch.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/sch.elf $(B)/sch.bin
	python3 sw/bin2hex.py $(B)/sch.bin > sw/sch.hex

sched: sw/sch.hex
	$(IV) -o $(B)/sched_tb.vvp $(RTL_SOC) tb/sched_tb.v && $(VVP) $(B)/sched_tb.vvp

# ---- A extension (atomics) demo ---------------------------------------
sw/at.hex: sw/atomic_demo.c sw/firmware.c sw/firmware.h sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32ima_zicsr -mabi=ilp32 -nostdlib -nostartfiles \
	  -ffreestanding -O1 -I sw -T sw/link.ld sw/crt0.s sw/firmware.c sw/atomic_demo.c \
	  -o $(B)/at.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/at.elf $(B)/at.bin
	python3 sw/bin2hex.py $(B)/at.bin > sw/at.hex
	riscv64-unknown-elf-objcopy -O verilog --verilog-data-width=1 --only-section=.rodata \
	  $(B)/at.elf $(B)/at_data.vh
	tr -d '\r' < $(B)/at_data.vh > sw/at_data.hex

atomic: sw/at.hex
	$(IV) -o $(B)/atomic_tb.vvp $(RTL_SOC) tb/atomic_tb.v && $(VVP) $(B)/atomic_tb.vvp

# ---- FreeRTOS prep: Step 1, the 64-bit CLINT machine timer ------------
clint:
	$(IV) -o $(B)/clint_tb.vvp rtl/clint.v tb/clint_tb.v && $(VVP) $(B)/clint_tb.vvp

# ---- FreeRTOS prep: Step 2, the RTOS-sized SoC (smoke test) -----------
RTL_RTOS = rtl/alu.v rtl/regfile.v rtl/immgen.v rtl/control.v rtl/csr.v rtl/imem.v \
           rtl/dmem.v rtl/uart.v rtl/clint.v rtl/syscon.v rtl/cpu_core.v rtl/soc_rtos.v

sw/rs.hex: sw/rtos_smoke.c sw/firmware.c sw/firmware.h sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32ima_zicsr -mabi=ilp32 -nostdlib -nostartfiles \
	  -ffreestanding -O1 -I sw -T sw/link.ld sw/crt0.s sw/firmware.c sw/rtos_smoke.c \
	  -o $(B)/rs.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/rs.elf $(B)/rs.bin
	python3 sw/bin2hex.py $(B)/rs.bin > sw/rs.hex
	riscv64-unknown-elf-objcopy -O verilog --verilog-data-width=1 --only-section=.rodata $(B)/rs.elf $(B)/rs_data.vh
	tr -d '\r' < $(B)/rs_data.vh > sw/rs_data.hex

rtos-smoke: sw/rs.hex
	$(IV) -o $(B)/rtos_smoke_tb.vvp $(RTL_RTOS) tb/rtos_smoke_tb.v && $(VVP) $(B)/rtos_smoke_tb.vvp

# ---- FreeRTOS prep: Step 3, build the kernel + port + demo ------------
# Point FREERTOS_KERNEL at a clone of github.com/FreeRTOS/FreeRTOS-Kernel
FREERTOS_KERNEL ?= $(HOME)/FreeRTOS-Kernel
FR_PORT  = $(FREERTOS_KERNEL)/portable/GCC/RISC-V
PICOLIBC_INC = /usr/lib/picolibc/riscv64-unknown-elf/include
PICOLIBC_LIB = /usr/lib/picolibc/riscv64-unknown-elf/lib/rv32im/ilp32
FR_INC   = -isystem $(PICOLIBC_INC) -I sw/freertos -I sw -I $(FREERTOS_KERNEL)/include -I $(FR_PORT) \
           -I $(FR_PORT)/chip_specific_extensions/RV32I_CLINT_no_extensions
FR_SRC   = sw/freertos/start.S sw/freertos/main.c sw/picolibc_retarget.c \
           $(FREERTOS_KERNEL)/tasks.c $(FREERTOS_KERNEL)/list.c $(FREERTOS_KERNEL)/queue.c \
           $(FR_PORT)/port.c $(FR_PORT)/portASM.S \
           $(FREERTOS_KERNEL)/portable/MemMang/heap_4.c
FRCFLAGS = -march=rv32ima_zicsr -mabi=ilp32 -nostdlib -nostartfiles -ffreestanding -O2 -g -Wno-unused-parameter

freertos:
	@test -d "$(FREERTOS_KERNEL)" || { echo ">> Set FREERTOS_KERNEL=/path/to/FreeRTOS-Kernel"; echo ">> git clone https://github.com/FreeRTOS/FreeRTOS-Kernel"; exit 1; }
	riscv64-unknown-elf-gcc $(FRCFLAGS) $(FR_INC) -T sw/freertos/freertos.ld $(FR_SRC) -L $(PICOLIBC_LIB) -lc -o $(B)/fr.elf -lgcc
	riscv64-unknown-elf-size $(B)/fr.elf
	riscv64-unknown-elf-objcopy -O binary $(B)/fr.elf $(B)/fr.bin
	python3 sw/bin2hex.py $(B)/fr.bin > sw/freertos/fr.hex
	riscv64-unknown-elf-objcopy -O verilog --verilog-data-width=1 --only-section=.rodata --only-section=.data $(B)/fr.elf $(B)/fr_data.vh
	tr -d '\r' < $(B)/fr_data.vh > sw/freertos/fr_data.hex
	@echo "OK: built FreeRTOS image (sw/freertos/fr.hex)"

freertos-run: ## run the prebuilt FreeRTOS image on soc_rtos (needs sw/freertos/fr.hex)
	$(IV) -o $(B)/freertos_tb.vvp $(RTL_RTOS) tb/freertos_tb.v && $(VVP) $(B)/freertos_tb.vvp

# ---- FreeRTOS on the synthesizable BRAM SoC (Zynq-7010 target) --------
RTL_RTOS_FPGA = rtl/alu.v rtl/regfile.v rtl/immgen.v rtl/control.v rtl/csr.v rtl/timer.v \
                rtl/uart_tx.v rtl/uart_hw.v rtl/clint.v rtl/bram_rom.v rtl/bram_ram.v \
                rtl/cpu_mc.v rtl/soc_rtos_fpga.v
FRF_CFLAGS = -march=rv32im_zicsr -mabi=ilp32 -nostdlib -nostartfiles -ffreestanding -O2 -g -Wno-unused-parameter

freertos-fpga: ## build FreeRTOS image for the synthesizable BRAM SoC (rv32im, 64KB)
	@test -d "$(FREERTOS_KERNEL)" || { echo ">> git clone FreeRTOS-Kernel and set FREERTOS_KERNEL=..."; exit 1; }
	riscv64-unknown-elf-gcc $(FRF_CFLAGS) $(FR_INC) -T sw/freertos/freertos_fpga.ld $(FR_SRC) -o $(B)/frf.elf -lgcc
	riscv64-unknown-elf-size $(B)/frf.elf
	riscv64-unknown-elf-objcopy -O binary $(B)/frf.elf $(B)/frf.bin
	python3 sw/bin2hex.py $(B)/frf.bin > sw/freertos/fr_fpga.hex
	@echo "OK: sw/freertos/fr_fpga.hex (init for BOTH bram_rom and bram_ram)"

freertos-fpga-run: ## run the synthesizable FreeRTOS SoC in simulation
	$(IV) -o $(B)/frf_tb.vvp $(RTL_RTOS_FPGA) tb/freertos_fpga_tb.v && $(VVP) $(B)/frf_tb.vvp

# ---- Debug stub: hardware debug module + gdb RSP server ---------------
RTL_DBG = rtl/alu.v rtl/regfile.v rtl/immgen.v rtl/control.v rtl/csr.v rtl/imem.v \
          rtl/dmem.v rtl/uart.v rtl/timer.v rtl/syscon.v rtl/cpu_core_dbg.v \
          rtl/debug_module.v rtl/soc_dbg.v

sw/dbg.hex: sw/dbg_demo.c sw/firmware.c sw/firmware.h sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32i_zicsr -mabi=ilp32 -nostdlib -nostartfiles \
	  -ffreestanding -O1 -I sw -T sw/link.ld sw/crt0.s sw/firmware.c sw/dbg_demo.c \
	  -o $(B)/dbg.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/dbg.elf $(B)/dbg.bin
	python3 sw/bin2hex.py $(B)/dbg.bin > sw/dbg.hex

debug: sw/dbg.hex   ## run a full debug session (halt/step/breakpoint/reg/mem) in sim
	$(IV) -o $(B)/debug_tb.vvp $(RTL_DBG) tb/debug_tb.v && $(VVP) $(B)/debug_tb.vvp

debug-selftest:     ## self-test the gdb RSP server (no hardware/gdb needed)
	python3 sw/gdbstub.py --selftest

# ---- Configurable UART: RX + TX, runtime baud/data-bits/parity/stop ----
RTL_UART_CFG = rtl/uart_rx.v rtl/uart_tx_cfg.v
RTL_UART_SOC = rtl/control.v rtl/alu.v rtl/regfile.v rtl/immgen.v rtl/csr.v rtl/cpu_mc.v \
               rtl/bram_rom.v rtl/bram_ram.v rtl/uart_rx.v rtl/uart_tx_cfg.v \
               rtl/uart_full.v rtl/soc_uart_fpga.v

uart-loopback: ## loopback-test the configurable UART (8N1/7E1/8O2/5N1 + parity errors)
	$(IV) -o $(B)/uart_loop_tb.vvp $(RTL_UART_CFG) tb/uart_loop_tb.v && $(VVP) $(B)/uart_loop_tb.vvp

sw/uart_echo.hex: sw/uart_echo.c sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles -ffreestanding \
	  -O1 -DCLKS=16 -I sw -T sw/link.ld sw/crt0.s sw/uart_echo.c -o $(B)/uecho.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/uecho.elf $(B)/uecho.bin
	python3 sw/bin2hex.py $(B)/uecho.bin > sw/uart_echo.hex

uart-echo: sw/uart_echo.hex ## end-to-end: CPU configures the UART, receives + echoes bytes
	$(IV) -o $(B)/uart_echo_tb.vvp $(RTL_UART_SOC) tb/uart_echo_tb.v && $(VVP) $(B)/uart_echo_tb.vvp

sw/uart_irq.hex: sw/uart_irq_demo.c sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32im_zicsr -mabi=ilp32 -nostdlib -nostartfiles -ffreestanding \
	  -O1 -DCLKS=64 -I sw -T sw/link.ld sw/crt0.s sw/uart_irq_demo.c -o $(B)/uirq.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/uirq.elf $(B)/uirq.bin
	python3 sw/bin2hex.py $(B)/uirq.bin > sw/uart_irq.hex

uart-irq: sw/uart_irq.hex ## interrupt-driven receive-to-idle: collect a whole message via IRQs, echo it
	$(IV) -o $(B)/uart_irq_tb.vvp $(RTL_UART_SOC) tb/uart_irq_tb.v && $(VVP) $(B)/uart_irq_tb.vvp

# ---- PLIC: multiplex several IRQ lines into one MEIP (Step 33) -------
RTL_PLIC = rtl/control.v rtl/alu.v rtl/regfile.v rtl/immgen.v rtl/csr.v rtl/cpu_mc.v \
           rtl/bram_rom.v rtl/bram_ram.v rtl/uart_rx.v rtl/uart_tx_cfg.v \
           rtl/uart_full.v rtl/plic.v rtl/soc_plic.v

sw/plic_demo.hex: sw/plic_demo.c sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32im_zicsr -mabi=ilp32 -nostdlib -nostartfiles -ffreestanding \
	  -O1 -I sw -T sw/link.ld sw/crt0.s sw/plic_demo.c -o $(B)/plic.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/plic.elf $(B)/plic.bin
	python3 sw/bin2hex.py $(B)/plic.bin > sw/plic_demo.hex

plic: sw/plic_demo.hex ## PLIC: per-source priority / enable / threshold / claim-complete into one MEIP
	$(IV) -o $(B)/plic_tb.vvp $(RTL_PLIC) tb/plic_tb.v && $(VVP) $(B)/plic_tb.vvp

# ---- C extension: 16-bit instructions, unaligned fetch (Step 34) -----
RTL_RVC = rtl/control.v rtl/alu.v rtl/regfile.v rtl/immgen.v rtl/csr.v \
          rtl/cpu_mc.v rtl/cpu_mc_c.v rtl/rvc_expand.v rtl/bram_rom.v rtl/bram_ram.v \
          rtl/uart_hw.v rtl/uart_tx.v rtl/timer.v rtl/soc_fpga.v rtl/soc_c.v

sw/rvc_demo.hex: sw/rvc_demo.c sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32imc_zicsr -mabi=ilp32 -nostdlib -nostartfiles -ffreestanding \
	  -O1 -T sw/link.ld sw/crt0.s sw/rvc_demo.c -o $(B)/rvc.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/rvc.elf $(B)/rvc.bin
	python3 sw/bin2hex.py $(B)/rvc.bin > sw/rvc_demo.hex

sw/rvc_demo_im.hex: sw/rvc_demo.c sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32im_zicsr -mabi=ilp32 -nostdlib -nostartfiles -ffreestanding \
	  -O1 -T sw/link.ld sw/crt0.s sw/rvc_demo.c -o $(B)/rvc_im.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/rvc_im.elf $(B)/rvc_im.bin
	python3 sw/bin2hex.py $(B)/rvc_im.bin > sw/rvc_demo_im.hex

rvc: sw/rvc_demo.hex sw/rvc_demo_im.hex ## C extension: same program as rv32im vs rv32imc, compare results + code size
	$(IV) -o $(B)/rvc_tb.vvp $(RTL_RVC) tb/rvc_tb.v && $(VVP) $(B)/rvc_tb.vvp
	@echo "---- code size: same program, two encodings ----"
	@riscv64-unknown-elf-size $(B)/rvc_im.elf $(B)/rvc.elf 2>/dev/null || echo "(rebuild hex files to see ELF sizes: rm sw/rvc_demo*.hex && make rvc)"

# ---- F extension: single-precision FPU, float regfile, fcsr (Step 35) -----
RTL_FP = rtl/control.v rtl/alu.v rtl/regfile.v rtl/immgen.v rtl/csr.v \
         rtl/fregfile.v rtl/fpu_f.v rtl/cpu_mc_f.v \
         rtl/bram_rom.v rtl/bram_ram.v rtl/soc_f.v

# Standalone FPU datapath check against host-float32 golden vectors. The
# vectors are committed under tb/; regenerate them with:
#   python3 sw/gen_fpu_vectors.py
fpu-unit: ## F: FPU datapath vs host-float32 golden vectors (arith + specials)
	$(IV) -o $(B)/fpu_tb.vvp rtl/fpu_f.v tb/fpu_tb.v
	@$(VVP) $(B)/fpu_tb.vvp
	@$(VVP) $(B)/fpu_tb.vvp +VEC=tb/fpu_vectors2.hex

sw/fp_demo.hex: sw/fp_demo.c sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32imf -mabi=ilp32f -nostdlib -nostartfiles \
	  -ffreestanding -O1 -T sw/link.ld sw/crt0.s sw/fp_demo.c -o $(B)/fp.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/fp.elf $(B)/fp.bin
	python3 sw/bin2hex.py $(B)/fp.bin > sw/fp_demo.hex

fp: sw/fp_demo.hex ## F: run compiled rv32imf float program on soc_f, check results
	$(IV) -o $(B)/fp_tb.vvp $(RTL_FP) tb/fp_tb.v && $(VVP) $(B)/fp_tb.vvp
	@riscv64-unknown-elf-size $(B)/fp.elf 2>/dev/null || echo "(rebuild: rm sw/fp_demo.hex && make fp)"

# ---- AXI4-Lite master to the PS: stall-capable bus (Step 36) ---------
RTL_AXI = rtl/control.v rtl/alu.v rtl/regfile.v rtl/immgen.v rtl/csr.v \
          rtl/cpu_mc_stall.v rtl/axi_lite_master.v rtl/bram_rom.v rtl/bram_ram.v \
          rtl/soc_axi.v

axi-lite: ## AXI: directed test of the bus->AXI4-Lite master vs a wait-state slave
	$(IV) -o $(B)/axi_lite_tb.vvp rtl/axi_lite_master.v tb/axi_lite_slave_mem.v tb/axi_lite_tb.v
	$(VVP) $(B)/axi_lite_tb.vvp

sw/axi_demo.hex: sw/axi_demo.c sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles \
	  -ffreestanding -O1 -T sw/link.ld sw/crt0.s sw/axi_demo.c -o $(B)/axi_demo.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/axi_demo.elf $(B)/axi_demo.bin
	python3 sw/bin2hex.py $(B)/axi_demo.bin > sw/axi_demo.hex

axi: sw/axi_demo.hex ## AXI: run a program that reaches the PS (DDR + peripheral) over AXI4-Lite
	$(IV) -o $(B)/axi_tb.vvp $(RTL_AXI) tb/axi_lite_slave_mem.v tb/axi_tb.v && $(VVP) $(B)/axi_tb.vvp

# ---- Real libc (picolibc): full printf + malloc (Step 37) -----------
# Replaces the hand-rolled mini-printf (firmware.c) and the FreeRTOS header
# shims with genuine picolibc. PICOLIBC_INC/PICOLIBC_LIB are defined in the
# FreeRTOS section above.
RTL_LIBC = rtl/control.v rtl/alu.v rtl/regfile.v rtl/immgen.v rtl/csr.v \
           rtl/cpu_mc.v rtl/bram_rom.v rtl/bram_ram.v rtl/uart.v rtl/soc_libc.v

sw/libc_demo.hex: sw/libc_demo.c sw/picolibc_crt0.S sw/picolibc_retarget.c sw/picolibc.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles -ffreestanding -O1 \
	  -isystem $(PICOLIBC_INC) -T sw/picolibc.ld \
	  sw/picolibc_crt0.S sw/picolibc_retarget.c sw/libc_demo.c \
	  -L $(PICOLIBC_LIB) -lc -lgcc -o $(B)/libc.elf
	riscv64-unknown-elf-objcopy -O binary $(B)/libc.elf $(B)/libc.bin
	python3 sw/bin2hex.py $(B)/libc.bin > sw/libc_demo.hex

libc: sw/libc_demo.hex ## real libc: picolibc printf + malloc on soc_libc, checked vs expected UART bytes
	$(IV) -o $(B)/libc_tb.vvp $(RTL_LIBC) tb/libc_tb.v && $(VVP) $(B)/libc_tb.vvp

# ---- Memory-isolated processes: scheduler + MMU (per-task satp) (Step 38) --
# Reuses the synthesizable MMU SoC (cpu_mc_mmu + timer); the merge is entirely
# in software -- a page table per task, and a satp reload in the context switch.
sw/smmu.hex: sw/sched_mmu.c sw/sched_mmu_asm.S sw/firmware.h sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32im_zicsr -mabi=ilp32 -nostdlib -nostartfiles \
	  -ffreestanding -O1 -I sw -T sw/link.ld sw/crt0.s sw/sched_mmu_asm.S sw/sched_mmu.c \
	  -o $(B)/smmu.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/smmu.elf $(B)/smmu.bin
	python3 sw/bin2hex.py $(B)/smmu.bin > sw/smmu.hex

sched-mmu: sw/smmu.hex ## isolated processes: per-task page tables, satp switched on context switch
	$(IV) -o $(B)/sched_mmu_tb.vvp $(RTL_FPGA_MMU) tb/sched_mmu_tb.v && $(VVP) $(B)/sched_mmu_tb.vvp

# ----- Step 39: supervisor mode + trap delegation (medeleg/mideleg) -----
# A new core (cpu_mc_s) and CSR block (csr_s) add S-mode and per-cause trap
# delegation. medeleg/mideleg route an ecall, an illegal instruction, and a
# software interrupt from U straight to an S-mode kernel, bypassing M.
RTL_SMODE = rtl/alu.v rtl/regfile.v rtl/immgen.v rtl/control.v rtl/csr_s.v \
            rtl/timer.v rtl/uart_tx.v rtl/uart_hw.v rtl/bram_rom.v \
            rtl/bram_ram.v rtl/cpu_mc_s.v rtl/soc_s.v

sw/smode.hex: sw/smode_demo.c sw/smode_asm.S sw/crt0.s sw/link.ld sw/bin2hex.py
	riscv64-unknown-elf-gcc -march=rv32i_zicsr -mabi=ilp32 -nostdlib -nostartfiles \
	  -ffreestanding -O1 -I sw -T sw/link.ld sw/crt0.s sw/smode_asm.S sw/smode_demo.c \
	  -o $(B)/smode.elf -lgcc
	riscv64-unknown-elf-objcopy -O binary $(B)/smode.elf $(B)/smode.bin
	python3 sw/bin2hex.py $(B)/smode.bin > sw/smode.hex

smode: sw/smode.hex ## supervisor mode: medeleg/mideleg delegate U/S traps to an S-mode kernel
	$(IV) -o $(B)/smode_tb.vvp $(RTL_SMODE) tb/smode_tb.v && $(VVP) $(B)/smode_tb.vvp

# ----- Step 40: the official riscv-tests suite -------------------------
# riscv-tests is the reference per-instruction suite. tools/rvtests fetches
# it into third_party/riscv-tests on first use (gitignored, pinned commit),
# builds every test against our own target environment in
# tests/riscv-tests/env/, and runs it on a compiled-once harness.
#
#   make riscv-tests                       # default core (cpu_mc)
#   make riscv-tests CORE=all              # every core + summary matrix
#   make riscv-tests CORE=pipe ARGS="add sra"
#   make riscv-tests ARGS=--list
#
# Cores: mc (cpu_mc) · mc_c (cpu_mc_c) · mc_f (cpu_mc_f) · mc_tlb (cpu_mc_tlb, Sv32 on)
#        pipe_u / pipe_u_vm (cpu_pipe_u: body in M / in U with Sv32 on)
#        pipe_c / pipe_c_vm (cpu_pipe_u behind small I/D caches on slow memory)
#        sc (cpu_core) · pipe (cpu_pipe_trap) · all
riscv-tests: ## official riscv-tests: rv32ui/um/ua/uc/uf per-instruction suite
	python3 tools/rvtests --core $(or $(CORE),mc) $(ARGS)

riscv-tests-all: ## the whole suite on every core, with a summary matrix
	python3 tools/rvtests --core all

riscv-tests-fetch: ## clone/refresh third_party/riscv-tests at the pinned commit
	python3 tools/rvtests --fetch
