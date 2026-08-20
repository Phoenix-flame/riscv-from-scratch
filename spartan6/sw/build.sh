#!/usr/bin/env bash
# =====================================================================
# build.sh  -  compile a program for the Spartan-6 SoC
# ---------------------------------------------------------------------
#   sw/build.sh                                  # sw/hello.c  -> sw/hello.hex
#   sw/build.sh sw/boot.c                        # the bootloader
#   LDSCRIPT=sw/link_app.ld sw/build.sh sw/myapp.c
#
# Outputs, named after the source file:
#   build/<name>.elf   build/<name>.bin   build/<name>.dis   sw/<name>.hex
#
# The .hex is what s6_ram loads -- in simulation via $readmemh, and in
# hardware as the block RAM's initial contents baked into the bitstream.
# The .bin is what tools/s6load.py sends over the serial bootloader.
#
# -march=rv32imac_zicsr_zifencei is exactly what the core implements. The
# C extension is on, so the image is roughly 25-30% smaller than rv32im
# -- which matters when the whole program has to fit in 16 KB.
#
# Environment overrides:
#   NAME       output base name         (default: the source file's name)
#   LDSCRIPT   linker script            (default sw/link.ld, i.e. base 0)
#   MEM_WORDS  words to pad the .hex to (default 4096, = s6_soc default)
#   OPT        optimisation level       (default -Os)
# =====================================================================
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
SRC="${1:-$HERE/hello.c}"
NAME="${NAME:-$(basename "${SRC%.*}")}"

LDSCRIPT="${LDSCRIPT:-$HERE/link.ld}"
MEM_WORDS="${MEM_WORDS:-4096}"
OPT="${OPT:--Os}"

GCC=${GCC:-riscv64-unknown-elf-gcc}
OC=${OC:-riscv64-unknown-elf-objcopy}
OD=${OD:-riscv64-unknown-elf-objdump}
SZ=${SZ:-riscv64-unknown-elf-size}

mkdir -p "$ROOT/build"

"$GCC" -march=rv32imac_zicsr_zifencei -mabi=ilp32 \
       $OPT -ffreestanding -nostdlib -nostartfiles -fno-builtin \
       -ffunction-sections -fdata-sections \
       -Wl,--gc-sections -Wl,--no-warn-rwx-segments \
       -Wall -Wextra -I"$HERE" \
       -T "$LDSCRIPT" \
       "$HERE/crt0.S" "$HERE/bsp.c" "$SRC" \
       -o "$ROOT/build/$NAME.elf" -lgcc

"$OC" -O binary "$ROOT/build/$NAME.elf" "$ROOT/build/$NAME.bin"
python3 "$HERE/bin2hex.py" "$ROOT/build/$NAME.bin" "$MEM_WORDS" > "$HERE/$NAME.hex"
"$OD" -d -S "$ROOT/build/$NAME.elf" > "$ROOT/build/$NAME.dis"

echo "built sw/$NAME.hex and build/$NAME.bin" \
     "($(stat -c%s "$ROOT/build/$NAME.bin") bytes of $((MEM_WORDS*4)))"
"$SZ" "$ROOT/build/$NAME.elf" 2>/dev/null || true
