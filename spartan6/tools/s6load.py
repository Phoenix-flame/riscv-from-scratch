#!/usr/bin/env python3
# =====================================================================
# s6load.py  -  upload a program to the s6 SoC over its serial port
# ---------------------------------------------------------------------
# Talks to sw/boot.c, the bootloader that lives in the low 2 KB of block
# RAM. Because that RAM is unified -- one dual-port array behind both the
# fetch port and the data port -- a program running from it can write a
# new program into it and jump there. So changing firmware costs a second
# instead of a synthesis run.
#
#   tools/s6load.py -p /dev/ttyUSB1 build/hello.bin
#   tools/s6load.py -p /dev/ttyUSB1 build/hello.bin --term
#   tools/s6load.py -p /dev/ttyUSB1 --term          # console only
#
# The image must be linked for the load address (sw/link_app.ld, base
# 0x800). Build it with:
#
#   LDSCRIPT=sw/link_app.ld sw/build.sh sw/hello.c
#
# Requires pyserial:  pip install pyserial
# =====================================================================
import argparse
import struct
import sys
import time

try:
    import serial
except ImportError:
    sys.exit("pyserial is missing:  pip install pyserial")

MAGIC = b"S6LD"


def load(port, image, entry, verbose=True):
    payload = open(image, "rb").read()
    if not payload:
        sys.exit(f"{image} is empty")
    checksum = sum(payload) & 0xFFFFFFFF

    if verbose:
        print(f"[s6load] {image}: {len(payload)} bytes -> 0x{entry:08x}")

    port.reset_input_buffer()
    port.write(MAGIC)
    port.flush()

    r = port.read(1)
    if r != b"R":
        sys.exit(f"[s6load] no 'R' from the bootloader (got {r!r}).\n"
                 "         Is the board sitting in s6boot? Press the reset "
                 "button and try again.")

    port.write(struct.pack("<II", len(payload), entry))

    # Chunked so a slow board cannot overrun the FIFO on a burst write,
    # and so there is something to show a progress line with.
    step = 256
    for off in range(0, len(payload), step):
        port.write(payload[off:off + step])
        port.flush()
        if verbose and (off // step) % 8 == 0:
            pct = 100 * min(off + step, len(payload)) // len(payload)
            print(f"\r[s6load] {pct:3d}%", end="", flush=True)
    if verbose:
        print("\r[s6load] 100%")

    port.write(struct.pack("<I", checksum))
    port.flush()

    r = port.read(1)
    if r == b"K":
        if verbose:
            print(f"[s6load] ok, running from 0x{entry:08x}")
        return True
    if r == b"E":
        sys.exit("[s6load] checksum mismatch -- the board rejected the image")
    if r == b"B":
        sys.exit(f"[s6load] the board refused 0x{entry:08x}: the image would "
                 "overrun the bootloader's stack or fall outside block RAM")
    sys.exit(f"[s6load] unexpected reply {r!r}")


def terminal(port):
    """Dump whatever the board prints; Ctrl-C to stop."""
    print("[s6load] console (Ctrl-C to quit)\n" + "-" * 60)
    try:
        while True:
            data = port.read(port.in_waiting or 1)
            if data:
                sys.stdout.write(data.decode("utf-8", "replace"))
                sys.stdout.flush()
            else:
                time.sleep(0.01)
    except KeyboardInterrupt:
        print("\n" + "-" * 60)


def main():
    ap = argparse.ArgumentParser(description="upload firmware to the s6 SoC")
    ap.add_argument("image", nargs="?", help="raw .bin from objcopy")
    ap.add_argument("-p", "--port", default="/dev/ttyUSB1",
                    help="serial device (default /dev/ttyUSB1)")
    ap.add_argument("-b", "--baud", type=int, default=115200)
    ap.add_argument("-e", "--entry", type=lambda s: int(s, 0), default=0x800,
                    help="load address and entry point (default 0x800)")
    ap.add_argument("-t", "--term", action="store_true",
                    help="stay attached as a console afterwards")
    ap.add_argument("--timeout", type=float, default=5.0)
    args = ap.parse_args()

    if not args.image and not args.term:
        ap.error("give an image to upload, --term, or both")

    with serial.Serial(args.port, args.baud, timeout=args.timeout) as port:
        if args.image:
            load(port, args.image, args.entry)
        if args.term:
            port.timeout = 0
            terminal(port)


if __name__ == "__main__":
    main()
