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
import os
import queue
import struct
import sys
import threading
import time

try:
    import serial
except ImportError:
    sys.exit("pyserial is missing:  pip install pyserial")

MAGIC = b"S6LD"


# ---------------------------------------------------------------------
# Pacing
# ---------------------------------------------------------------------
# The receiver in rtl/s6_uart_rx.v accumulates a fraction of an oversample
# tick per frame, so on a continuous back-to-back stream it slips half a
# bit after about 21 bytes and everything after that is mis-framed --
# mis-framed, not dropped, which is why a 3 KB image used to arrive and
# draw no reply at all. An idle gap resynchronises it, and bursts of 16
# bytes or fewer followed by a real gap come back byte-exact, so that is
# what this sends. Raise CHUNK once the receiver is fixed; --chunk 0
# turns pacing off and writes at full rate.
CHUNK = 8            # bytes per burst (measured safe; the slip starts ~21)
GAP   = 0.001        # seconds of quiet after each burst


def send(port, data, chunk=CHUNK, gap=GAP):
    """Write data in bursts small enough that the receiver keeps framing."""
    if not chunk:
        port.write(data)
        port.flush()
        return
    for off in range(0, len(data), chunk):
        port.write(data[off:off + chunk])
        port.flush()
        if gap:
            time.sleep(gap)


def load(port, image, entry, verbose=True, chunk=CHUNK, gap=GAP):
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

    send(port, struct.pack("<II", len(payload), entry), chunk, gap)

    # Paced, not blasted: see the note on CHUNK above. step only controls
    # how often the progress line is redrawn.
    step = max(chunk, 1) * 32
    for off in range(0, len(payload), step):
        send(port, payload[off:off + step], chunk, gap)
        if verbose:
            pct = 100 * min(off + step, len(payload)) // len(payload)
            print(f"\r[s6load] {pct:3d}%", end="", flush=True)
    if verbose:
        print("\r[s6load] 100%")

    send(port, struct.pack("<I", checksum), chunk, gap)

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


def _win_char_mode():
    """Windows console: character-at-a-time, no local echo.

    Returns a restore callable, or None when stdin is not a console (piped
    or redirected), in which case the console is left exactly as found and
    input simply arrives a line at a time.
    """
    import ctypes
    ENABLE_LINE_INPUT, ENABLE_ECHO_INPUT = 0x0002, 0x0004
    try:
        k32 = ctypes.windll.kernel32
        h = k32.GetStdHandle(-10)                  # STD_INPUT_HANDLE
        mode = ctypes.c_uint32()
        if not k32.GetConsoleMode(h, ctypes.byref(mode)):
            return None
        keep = mode.value & ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT)
        if not k32.SetConsoleMode(h, keep):
            return None
    except Exception:
        return None
    return lambda: k32.SetConsoleMode(h, mode.value)


def _stdin_reader(q):
    """Feed stdin bytes into a queue. Blocking, so it lives on its own thread.

    os.read on the raw descriptor, not sys.stdin.buffer.read: this thread is
    a daemon parked in a blocking read at exit, and the buffered reader would
    still be holding its lock, which makes the interpreter abort on shutdown
    with "could not acquire lock ... at interpreter shutdown".
    """
    try:
        fd = sys.stdin.fileno()
    except Exception:
        return
    while True:
        try:
            b = os.read(fd, 256)
        except Exception:
            return
        if not b:
            return
        q.put(b)


def _trace(tag, data):
    """Show one direction of the console as hex plus printable text."""
    for off in range(0, len(data), 16):
        row = data[off:off + 16]
        hexs = " ".join("%02x" % b for b in row)
        text = "".join(chr(b) if 32 <= b < 127 else "." for b in row)
        sys.stdout.write("%s %-47s |%s|%s" % (tag, hexs, text, chr(10)))
    sys.stdout.flush()


def terminal(port, chunk=CHUNK, gap=GAP, trace=False):
    """A two-way console: board output to the screen, keystrokes to the board.

    Keys are read on a background thread rather than polled, because the
    poll-the-console approach (msvcrt.kbhit) does not see keystrokes in
    every Windows host -- they stay in the shell, get echoed locally, and
    never reach the board, which looks exactly like a dead link. A blocking
    read on stdin works the same way everywhere.

    Local echo is turned off where possible, because the board echoes
    keystrokes back itself; if it cannot be turned off you will see each
    character twice, once from the shell and once from the board.
    """
    print("[s6load] console (Ctrl-C to quit)")
    print("-" * 60)

    if os.name == "nt":
        restore = _win_char_mode()
    else:
        try:
            import termios, tty
            fd = sys.stdin.fileno()
            saved = termios.tcgetattr(fd)
            tty.setcbreak(fd)
            restore = lambda: termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        except Exception:
            restore = None

    keys_q = queue.Queue()
    threading.Thread(target=_stdin_reader, args=(keys_q,), daemon=True).start()

    CR, LF, ETX = bytes([13]), bytes([10]), bytes([3])
    try:
        while True:
            data = port.read(port.in_waiting or 1)
            if data:
                if trace:
                    _trace("rx<", data)
                else:
                    sys.stdout.write(data.decode("utf-8", "replace"))
                    sys.stdout.flush()

            keys = b""
            while True:
                try:
                    keys += keys_q.get_nowait()
                except queue.Empty:
                    break
            if keys:
                if ETX in keys:                     # Ctrl-C as a byte, raw mode
                    break
                # Enter must reach the board as a bare CR: hello.c echoes the
                # CR and adds its own LF, so forwarding both doubles the gap.
                keys = keys.replace(CR + LF, CR).replace(LF, CR)
                if trace:
                    _trace("tx>", keys)
                send(port, keys, chunk, gap)
            elif not data:
                time.sleep(0.005)
    except KeyboardInterrupt:
        pass
    finally:
        if restore:
            restore()
    print(chr(10) + "-" * 60)

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
    ap.add_argument("--trace", action="store_true",
                    help="show both directions as hex; the board reply is "
                         "otherwise indistinguishable from your own typing")
    ap.add_argument("--chunk", type=int, default=CHUNK,
                    help="bytes per burst (default %d; 0 disables pacing)" % CHUNK)
    ap.add_argument("--gap", type=float, default=GAP,
                    help="seconds of quiet after each burst (default %g)" % GAP)
    args = ap.parse_args()

    if not args.image and not args.term:
        ap.error("give an image to upload, --term, or both")

    with serial.Serial(args.port, args.baud, timeout=args.timeout) as port:
        if args.image:
            load(port, args.image, args.entry,
                 chunk=args.chunk, gap=args.gap)
        if args.term:
            port.timeout = 0
            terminal(port, chunk=args.chunk, gap=args.gap, trace=args.trace)


if __name__ == "__main__":
    main()
