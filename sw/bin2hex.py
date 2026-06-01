#!/usr/bin/env python3
# bin2hex.py - convert a raw little-endian binary into one 32-bit
# hex word per line, suitable for Verilog $readmemh.
#
# Usage: python3 bin2hex.py prog.bin > prog.hex
import sys

data = open(sys.argv[1], "rb").read()
# Pad to a multiple of 4 bytes.
if len(data) % 4:
    data += b"\x00" * (4 - len(data) % 4)
for i in range(0, len(data), 4):
    word = int.from_bytes(data[i:i+4], "little")   # RISC-V is little-endian
    print("%08x" % word)
