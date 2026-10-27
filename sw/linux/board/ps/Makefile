# The Cortex-A9 program for riscv_linux (Steps 54, 56): run from OCM by
# OpenZynq's `make run PROJECT=riscv_linux`, or, as the FSBL of a BOOT.BIN,
# by the BootROM. startup.S, linker.ld and xil_io.h are OpenZynq's own
# (projects/ddr_test/ps), copied in by `make linux-oz`.
# ps7_init.c/.h: `make vivado-init` (the Vivado export known to work on the
# Mitra) or `make genz` (GenZ's; not yet run on a board).
# `make test`: bootbin.c and qspi.c on this PC, against a model (test/).
CROSS_COMPILE ?= arm-none-eabi-
CC := $(CROSS_COMPILE)gcc
ARCH := -mcpu=cortex-a9 -marm -mfloat-abi=soft
# the MMU is off: every access is strongly ordered, where an unaligned one
# faults; and there is no libc for GCC to turn copy loops into memcpy() calls
CFLAGS := $(ARCH) -std=c11 -O2 -g -Wall -Wextra -Wno-error=sign-compare -ffreestanding \
 -fno-builtin -ffunction-sections -fdata-sections -mno-unaligned-access \
 -fno-tree-loop-distribute-patterns -I.
SOURCES := main.c bootbin.c qspi.c pcap.c ps7_init.c
HEADERS := zynq.h bootbin.h qspi.h pcap.h ps7_init.h
BOARD ?= mitra7010
HOSTCC ?= cc

.PHONY: all clean genz vivado-init test
all: build/riscv_linux.elf

build/riscv_linux.elf: $(SOURCES) $(HEADERS) startup.S linker.ld
	@test -f ps7_init.c || { echo 'No ps7_init.c here: run make vivado-init (or make genz) first'; exit 1; }
	mkdir -p build
	$(CC) $(CFLAGS) -nostdlib -Wl,-T,linker.ld,--gc-sections,-Map,build/riscv_linux.map \
	 $(SOURCES) startup.S -lgcc -o $@
	$(CROSS_COMPILE)size $@

test: build/host_test test/mkbootbin.py
	python3 test/mkbootbin.py build/test-BOOT.BIN
	build/host_test build/test-BOOT.BIN

build/host_test: test/host_test.c bootbin.c qspi.c zynq.h bootbin.h qspi.h
	mkdir -p build
	$(HOSTCC) -std=c11 -O1 -g -Wall -Wextra -DPS_HOST_TEST -I. test/host_test.c bootbin.c qspi.c -o $@

vivado-init:
	cp ../../../boards/$(BOARD)/ps7_init_vivado/ps7_init.c ../../../boards/$(BOARD)/ps7_init_vivado/ps7_init.h .

genz:
	@test -f ../../../boards/$(BOARD)/ps7_init/ps7_init.c || { \
	 echo 'Missing generated PS init: run make ddr-init from the repository root'; exit 1; }
	cp ../../../boards/$(BOARD)/ps7_init/ps7_init.c ../../../boards/$(BOARD)/ps7_init/ps7_init.h .

clean:
	rm -rf build
