#!/usr/bin/env bash
# build.sh - assemble a RISC-V .s file into a .hex for our instruction memory.
# Usage: sw/build.sh sw/sum.s   ->   produces sw/sum.hex
set -e

SRC="$1"
[ -z "$SRC" ] && { echo "usage: $0 <file.s>"; exit 1; }

BASE="$(basename "${SRC%.s}")"
DIR="$(dirname "$SRC")"
OUT="$DIR/$BASE"

AS=riscv64-unknown-elf-as
LD=riscv64-unknown-elf-ld
OC=riscv64-unknown-elf-objcopy
OD=riscv64-unknown-elf-objdump

$AS -march=rv32i -mabi=ilp32 "$SRC"        -o "$OUT.o"
$LD -m elf32lriscv -Ttext=0x0 "$OUT.o"     -o "$OUT.elf"
$OC -O binary "$OUT.elf"                       "$OUT.bin"
python3 "$DIR/bin2hex.py" "$OUT.bin"         > "$OUT.hex"

echo "Built $OUT.hex"
echo "--- disassembly ---"
$OD -d "$OUT.elf"
