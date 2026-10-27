# The Cortex-A9 program for riscv_linux (Step 54), run from OCM by OpenZynq's
# `make run PROJECT=riscv_linux`. startup.S, linker.ld and xil_io.h are
# OpenZynq's own (projects/ddr_test/ps), copied in by `make linux-oz`.
# ps7_init.c/.h: `make vivado-init` (the Vivado export known to work on the
# Mitra) or `make genz` (GenZ's; not yet run on a board).
CROSS_COMPILE ?= arm-none-eabi-
CC := $(CROSS_COMPILE)gcc
ARCH := -mcpu=cortex-a9 -marm -mfloat-abi=soft
CFLAGS := $(ARCH) -std=c11 -O2 -g -Wall -Wextra -Wno-error=sign-compare -ffreestanding \
 -fno-builtin -ffunction-sections -fdata-sections -I.
SOURCES := main.c ps7_init.c
BOARD ?= mitra7010

.PHONY: all clean genz vivado-init
all: build/riscv_linux.elf

build/riscv_linux.elf: $(SOURCES) ps7_init.h startup.S linker.ld
	@test -f ps7_init.c || { echo 'No ps7_init.c here: run make vivado-init (or make genz) first'; exit 1; }
	mkdir -p build
	$(CC) $(CFLAGS) -nostdlib -Wl,-T,linker.ld,--gc-sections,-Map,build/riscv_linux.map \
	 $(SOURCES) startup.S -lgcc -o $@
	$(CROSS_COMPILE)size $@

vivado-init:
	cp ../../../boards/$(BOARD)/ps7_init_vivado/ps7_init.c ../../../boards/$(BOARD)/ps7_init_vivado/ps7_init.h .

genz:
	@test -f ../../../boards/$(BOARD)/ps7_init/ps7_init.c || { \
	 echo 'Missing generated PS init: run make ddr-init from the repository root'; exit 1; }
	cp ../../../boards/$(BOARD)/ps7_init/ps7_init.c ../../../boards/$(BOARD)/ps7_init/ps7_init.h .

clean:
	rm -rf build
