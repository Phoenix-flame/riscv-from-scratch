#!/usr/bin/env python3
"""A BOOT.BIN laid out as zynq-mkbootimage lays one out, for `make test` only.

The real one comes from mkbootimage (OpenZynq's container) and a .bif. This
mirrors that tool's Zynq output (src/arch/zynq.c, src/bootrom.c): the boot
header with its offsets at 0x98/0x9c, the image header table at 0x8c0, the
partition headers at 0xc80, the partitions from 0x1700 on 64-byte bounds; a
bitstream's words byte-swapped from the .bit, with a NOOP appended.

    mkbootbin.py OUT [--rvbi IMAGE] [--bit RAW_BITSTREAM]

With no inputs it makes a small RVBI image and a fake bitstream (the sync
sequence, then random words): enough for the parser and the flash writer.
"""
import argparse
import binascii
import random
import struct

IMG_HDR_OFF, PART_HDR_OFF, BINS_OFF = 0x8c0, 0xc80, 0x1700
ATTR_PS, ATTR_PL, ATTR_GENERAL = 1 << 4, 2 << 4, 1


def crc32(b):
    return binascii.crc32(b) & 0xFFFFFFFF


def rvbi(entry, segs, cmdline=b""):
    """sw/boot/bootimg.h, as tools/rvboot make_image writes it"""
    data = b"".join(d for _, d in segs)
    table = b"".join(struct.pack("<III", a, len(d), len(d)) for a, d in segs)
    hdr = struct.pack("<IHHIIHHIII", 0x49425652, 1, len(segs), entry, 0, len(cmdline), 0,
                      len(data), crc32(data), 0)
    return hdr[:-4] + struct.pack("<I", crc32(hdr + table + cmdline)) + table + cmdline + data


def words_le(b):
    return b + b"\xff" * (-len(b) % 4)


def build(parts):
    """parts: [(attr, payload bytes already in BOOT.BIN order)]"""
    out = bytearray(b"\xff" * BINS_OFF)
    hdrs, data, off = [], bytearray(), BINS_OFF // 4
    for attr, payload in parts:
        payload = words_le(payload)
        nw = len(payload) // 4
        hdrs.append((nw, off, attr))
        payload += b"\xff" * (-len(payload) % 64)
        data += payload
        off += len(payload) // 4
    # boot header
    struct.pack_into("<8I", out, 0, *[0xEAFFFFFE] * 8)
    fsbl_words = hdrs[0][0]
    fields = [0xAA995566, 0x584C4E58, 0, 0x01010000, BINS_OFF, 4 * fsbl_words, 0, 0, 4 * fsbl_words, 1]
    struct.pack_into("<10I", out, 0x20, *fields)
    struct.pack_into("<I", out, 0x48, ~sum(fields) & 0xFFFFFFFF)
    user0 = [0] * 21
    user0[19], user0[20] = IMG_HDR_OFF, PART_HDR_OFF
    struct.pack_into("<21I", out, 0x4c, *user0)
    for i in range(256):
        struct.pack_into("<II", out, 0xa0 + 8 * i, 0xFFFFFFFF, 0)
    # image header table, then one image header (64 bytes) per partition
    first_img = IMG_HDR_OFF + 64
    struct.pack_into("<5I", out, IMG_HDR_OFF, 0x01020000, len(hdrs), PART_HDR_OFF // 4, first_img // 4, 0)
    for i in range(len(hdrs)):
        a = first_img + 64 * i
        nxt = 0 if i + 1 == len(hdrs) else (a + 64) // 4
        struct.pack_into("<4I", out, a, nxt, PART_HDR_OFF // 4 + 16 * i, 0, 1)
        out[a + 16:a + 48] = (b"part%d" % i).ljust(32, b"\0")
    for i, (nw, off, attr) in enumerate(hdrs):
        w = [nw, nw, nw, 0, 0, off, attr, 1, 0, (first_img + 64 * i) // 4, 0, 0, 0, 0, 0]
        struct.pack_into("<16I", out, PART_HDR_OFF + 64 * i, *w, ~sum(w) & 0xFFFFFFFF)
    return bytes(out + data)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--rvbi")
    ap.add_argument("--bit", help="a raw bitstream, its words big-endian as in a .bit file")
    a = ap.parse_args()
    rnd = random.Random(56)
    fsbl = bytes(rnd.getrandbits(8) for _ in range(30000))          # stands in for the ELF's code
    if a.bit:
        raw = open(a.bit, "rb").read()
    else:
        raw = struct.pack(">13I", *[0xFFFFFFFF] * 8, 0x000000BB, 0x11220044, 0xFFFFFFFF, 0xFFFFFFFF,
                          0xAA995566) + bytes(rnd.getrandbits(8) for _ in range(100000))
    bit = b"".join(struct.pack("<I", w) for w in struct.unpack(">%dI" % (len(raw) // 4), raw))
    bit += bytes([0, 0, 0, 0x20])
    img = open(a.rvbi, "rb").read() if a.rvbi else rvbi(0x80400000, [
        (0x80400000, bytes(rnd.getrandbits(8) for _ in range(150001))),
        (0x81000000, bytes(rnd.getrandbits(8) for _ in range(77777)))], b"console=ttyS0,115200")
    boot = build([(ATTR_PS, fsbl), (ATTR_PL, bit), (ATTR_PS | ATTR_GENERAL, img)])
    open(a.out, "wb").write(boot)
    print(f"{a.out}: {len(boot):,} bytes (FSBL {len(fsbl):,}, bitstream {len(bit):,}, RVBI {len(img):,})")


if __name__ == "__main__":
    main()
