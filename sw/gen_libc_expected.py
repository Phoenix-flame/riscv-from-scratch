#!/usr/bin/env python3
# Emits the exact bytes libc_demo.c should print, with LF cooked to CRLF by the
# UART retarget. Writes one hex byte per line for the testbench to $readmemh.
lines = [
    "picolibc on rv32im: printf + malloc",
    "int=-42 uint=42 hex=0xdeadbeef char=Q",
    "width=[    7][7    ][00007]",
    "squares sum=140",
    "str='hello, world' len=12",
    "reuse ptr nonnull=1",
    "DONE",
]
out = "".join(s + "\n" for s in lines).replace("\n", "\r\n")
b = out.encode("ascii")
with open("tb/libc_expected.hex", "w") as f:
    for ch in b:
        f.write("%02x\n" % ch)
print("expected bytes:", len(b))
