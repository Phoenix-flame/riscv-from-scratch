#!/usr/bin/env bash
# cbuild.sh - compile a C file (+ crt0) into a .hex for instruction memory.
# Usage: sw/cbuild.sh sw/sum.c   ->   produces sw/cprog.hex
set -e

SRC="$1"
[ -z "$SRC" ] && { echo "usage: $0 <file.c>"; exit 1; }

GCC=riscv64-unknown-elf-gcc
OC=riscv64-unknown-elf-objcopy
OD=riscv64-unknown-elf-objdump
DIR="$(dirname "$SRC")"

# -nostdlib/-nostartfiles/-ffreestanding: no OS, no libc, no default crt0.
# -march=rv32i -mabi=ilp32: exactly the ISA our CPU implements.
$GCC -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles -ffreestanding -O1 \
     -T "$DIR/link.ld" "$DIR/crt0.s" "$SRC" -o build/cprog.elf

$OC -O binary build/cprog.elf build/cprog.bin
python3 "$DIR/bin2hex.py" build/cprog.bin > "$DIR/cprog.hex"

echo "Built $DIR/cprog.hex"
echo "--- disassembly ---"
$OD -d build/cprog.elf
