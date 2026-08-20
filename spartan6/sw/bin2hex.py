#!/usr/bin/env python3
# =====================================================================
# bin2hex.py - raw little-endian binary -> one 32-bit hex word per line
# ---------------------------------------------------------------------
# The format $readmemh wants for a `reg [31:0] mem [0:N-1]` array, which
# is what s6_ram is. Also what ISE's data2mem/BRAM init consumes after
# the .hex is turned into a .bmm-driven image.
#
#   python3 bin2hex.py firmware.bin [words] > firmware.hex
#
# If `words` is given the image is padded with zeros to that length, so
# the file always matches MEM_WORDS and $readmemh never leaves the tail
# of the memory as x in simulation.
# =====================================================================
import sys

if len(sys.argv) < 2:
    sys.exit("usage: bin2hex.py <file.bin> [words]")

data = open(sys.argv[1], "rb").read()
if len(data) % 4:
    data += b"\x00" * (4 - len(data) % 4)

words = [int.from_bytes(data[i:i + 4], "little") for i in range(0, len(data), 4)]

if len(sys.argv) > 2:
    target = int(sys.argv[2])
    if len(words) > target:
        sys.exit(f"image is {len(words)} words, memory holds {target}")
    words += [0] * (target - len(words))

print("\n".join("%08x" % w for w in words))
