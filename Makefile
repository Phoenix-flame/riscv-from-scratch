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
FR_INC   = -I sw/freertos/shim -I sw/freertos -I sw -I $(FREERTOS_KERNEL)/include -I $(FR_PORT) \
           -I $(FR_PORT)/chip_specific_extensions/RV32I_CLINT_no_extensions
FR_SRC   = sw/freertos/start.S sw/freertos/main.c sw/firmware.c \
           $(FREERTOS_KERNEL)/tasks.c $(FREERTOS_KERNEL)/list.c $(FREERTOS_KERNEL)/queue.c \
           $(FR_PORT)/port.c $(FR_PORT)/portASM.S \
           $(FREERTOS_KERNEL)/portable/MemMang/heap_4.c
FRCFLAGS = -march=rv32ima_zicsr -mabi=ilp32 -nostdlib -nostartfiles -ffreestanding -O2 -g -Wno-unused-parameter

freertos:
	@test -d "$(FREERTOS_KERNEL)" || { echo ">> Set FREERTOS_KERNEL=/path/to/FreeRTOS-Kernel"; echo ">> git clone https://github.com/FreeRTOS/FreeRTOS-Kernel"; exit 1; }
	riscv64-unknown-elf-gcc $(FRCFLAGS) $(FR_INC) -T sw/freertos/freertos.ld $(FR_SRC) -o $(B)/fr.elf -lgcc
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
