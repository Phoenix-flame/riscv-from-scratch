#!/usr/bin/env python3
"""vgen - random differential testing of the vector unit (Step 47).

    python3 tools/vtest/vgen.py --seed N [--count 60] [--vlen 128] --out DIR

Writes DIR/prog.S, a random but legal sequence of the vector instructions
rtl/vec_unit.v implements, and DIR/expect.hex, what memory must hold when it
halts according to a Python model of the RVV 1.0 semantics (tail and
masked-off elements undisturbed, as the RTL implements them). The program:

  1. loads all 32 vector registers from random data (whole-register loads),
  2. runs COUNT random instructions -- vsetvli with random SEW/LMUL/AVL,
     arithmetic .vv/.vx/.vi with and without masks, compares into masks,
     multiplies and multiply-adds, reductions, mask logic, slides, moves,
     unit-stride / strided / indexed / mask / whole-register loads and
     stores -- storing every scalar result (vmv.x.s, vcpop, vfirst, vl),
  3. stores all 32 vector registers.

tools/vtest/run.py assembles it, runs it on the RTL, and compares the whole
DATA..OUT memory with expect.hex.
"""
import argparse
import os
import random

DATA, INDEX, OUT_V, OUT_S, END = 0x2000, 0x3000, 0x4000, 0x5000, 0x6000


def sx(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


class Model:
    def __init__(self, vlen, mem):
        self.vlen, self.vlenb = vlen, vlen // 8
        self.v = bytearray(32 * self.vlenb)
        self.mem = mem                        # bytearray covering [0, END)
        self.vl, self.sew, self.lmul = 0, 8, 1.0
        self.out = []                         # scalar results, in order

    # ---- element access ----
    def eget(self, reg, i, eew):
        o = reg * self.vlenb + i * eew // 8
        return int.from_bytes(self.v[o:o + eew // 8], "little")

    def eset(self, reg, i, eew, val):
        o = reg * self.vlenb + i * eew // 8
        self.v[o:o + eew // 8] = (val & ((1 << eew) - 1)).to_bytes(eew // 8, "little")

    def bget(self, reg, i):
        o = reg * self.vlenb + i // 8
        return (self.v[o] >> (i % 8)) & 1

    def bset(self, reg, i, b):
        o = reg * self.vlenb + i // 8
        self.v[o] = (self.v[o] & ~(1 << (i % 8))) | (b << (i % 8))

    def mget(self, a, n):
        return int.from_bytes(self.mem[a:a + n], "little")

    def mset(self, a, n, val):
        self.mem[a:a + n] = (val & ((1 << (8 * n)) - 1)).to_bytes(n, "little")

    def vlmax(self, sew=None, lmul=None):
        return int(self.vlen // (sew or self.sew) * (lmul or self.lmul))

    def active(self, i, vm):
        return vm or self.bget(0, i)


def emul_ok(eew, sew, lmul):
    e = eew / sew * lmul
    return 1 / 8 <= e <= 8, e


class Gen:
    def __init__(self, seed, count, vlen):
        self.r = random.Random(seed)
        self.count, self.vlen = count, vlen
        self.asm = []
        mem = bytearray(END)
        for a in range(DATA, INDEX):
            mem[a] = self.r.randrange(256)
        self.m = Model(vlen, mem)
        self.init = None                      # memory image, filled in below
        self.slots = 0
        # index tables at INDEX: offsets (multiples of 4, < 256) as 8/16/32-bit values
        self.idx_tab = {}
        off = INDEX
        for eew in (8, 16, 32):
            self.idx_tab[eew] = off
            for i in range(self.vlen):         # enough for any VLMAX
                self.m.mset(off + i * eew // 8, eew // 8, 4 * self.r.randrange(64))
            off += self.vlen * 4
        self.init = bytes(mem)

    def emit(self, s):
        self.asm.append("    " + s)

    def li(self, reg, val):
        self.emit("li %s, %d" % (reg, sx(val, 32) if val >= 1 << 31 else val))

    def save_scalar(self, reg, val):
        self.emit("sw %s, %d(s1)" % (reg, 4 * self.slots))
        self.m.mset(OUT_S + 4 * self.slots, 4, val)
        self.slots += 1

    # ---- register-group allocation ----
    def group(self, emul, avoid=(), not_v0=False):
        n = max(1, int(emul))
        for _ in range(100):
            r = self.r.randrange(0, 32, n)
            rng = set(range(r, r + n))
            if not_v0 and 0 in rng:
                continue
            if any(rng & set(a) for a in avoid):
                continue
            return r, rng
        return None, None

    # ---- instruction kinds ----
    def vset(self):
        m = self.m
        while True:
            sew = self.r.choice([8, 16, 32])
            lmul = self.r.choice([0.125, 0.25, 0.5, 1, 2, 4, 8])
            if lmul < 1 and sew / lmul > 32:
                continue
            break
        vlmax = m.vlmax(sew, lmul)
        avl = self.r.choice([0, 1, vlmax, vlmax + 3, self.r.randrange(1, vlmax + 1)])
        lm = {0.125: "mf8", 0.25: "mf4", 0.5: "mf2", 1: "m1", 2: "m2", 4: "m4", 8: "m8"}[lmul]
        if self.r.random() < 0.15 and avl < 32:
            self.emit("vsetivli t0, %d, e%d, %s, ta, ma" % (avl, sew, lm))
        else:
            self.li("t2", avl)
            self.emit("vsetvli t0, t2, e%d, %s, ta, ma" % (sew, lm))
        m.sew, m.lmul, m.vl = sew, lmul, min(avl, vlmax)
        self.save_scalar("t0", m.vl)

    def arith(self):
        m, r = self.m, self.r
        ops = ["vadd", "vsub", "vrsub", "vand", "vor", "vxor", "vsll", "vsrl", "vsra",
               "vminu", "vmin", "vmaxu", "vmax", "vmul", "vmulh", "vmulhu", "vmulhsu",
               "vmacc", "vnmsac", "vmadd", "vnmsub", "vmerge", "vmv"]
        op = r.choice(ops)
        forms = {"vrsub": ["vx", "vi"], "vsub": ["vv", "vx"]}.get(op, ["vv", "vx", "vi"])
        if op in ("vminu", "vmin", "vmaxu", "vmax") or op.startswith("vmul") or op in ("vmacc", "vnmsac", "vmadd", "vnmsub"):
            forms = ["vv", "vx"]
        form = r.choice(forms)
        vm = r.random() < 0.6 if op not in ("vmerge", "vmv") else (op == "vmv")
        g = m.lmul if m.lmul >= 1 else 1
        vd, _ = self.group(g, not_v0=not vm)
        vs2, _ = self.group(g)
        vs1, _ = self.group(g)
        sew, mask = m.sew, (1 << m.sew) - 1
        x = r.randrange(1 << 32)
        simm = r.randrange(-16, 16)
        uimm = r.randrange(32)
        shift = op in ("vsll", "vsrl", "vsra")
        if form == "vx":
            self.li("t1", x)
        # assembly
        if op == "vmv":
            text = {"vv": "vmv.v.v v%d, v%d" % (vd, vs1), "vx": "vmv.v.x v%d, t1" % vd,
                    "vi": "vmv.v.i v%d, %d" % (vd, simm)}[form]
        elif op == "vmerge":
            text = {"vv": "vmerge.vvm v%d, v%d, v%d, v0" % (vd, vs2, vs1),
                    "vx": "vmerge.vxm v%d, v%d, t1, v0" % (vd, vs2),
                    "vi": "vmerge.vim v%d, v%d, %d, v0" % (vd, vs2, simm)}[form]
        elif op in ("vmacc", "vnmsac", "vmadd", "vnmsub"):
            src = "v%d" % vs1 if form == "vv" else "t1"
            text = "%s.%s v%d, %s, v%d" % (op, form, vd, src, vs2)
        else:
            src = {"vv": "v%d" % vs1, "vx": "t1", "vi": str(uimm if shift else simm)}[form]
            text = "%s.%s v%d, v%d, %s" % (op, form, vd, vs2, src)
        self.emit(text + ("" if vm or op == "vmerge" else ", v0.t"))
        # model
        new = {}
        for i in range(m.vl):
            if op != "vmerge" and not m.active(i, vm):
                continue
            a2 = m.eget(vs2, i, sew)
            a1 = {"vv": m.eget(vs1, i, sew) if form == "vv" else 0, "vx": x & mask,
                  "vi": (uimm if shift else simm) & mask}[form]
            ad = m.eget(vd, i, sew)
            s2, s1, sd = sx(a2, sew), sx(a1, sew), sx(ad, sew)
            sh = a1 & (sew - 1)
            res = {
                "vadd": lambda: a2 + a1, "vsub": lambda: a2 - a1, "vrsub": lambda: a1 - a2,
                "vand": lambda: a2 & a1, "vor": lambda: a2 | a1, "vxor": lambda: a2 ^ a1,
                "vsll": lambda: a2 << sh, "vsrl": lambda: a2 >> sh, "vsra": lambda: s2 >> sh,
                "vminu": lambda: min(a2, a1), "vmaxu": lambda: max(a2, a1),
                "vmin": lambda: min(s2, s1), "vmax": lambda: max(s2, s1),
                "vmul": lambda: s2 * s1, "vmulh": lambda: (s2 * s1) >> sew,
                "vmulhu": lambda: (a2 * a1) >> sew, "vmulhsu": lambda: (s2 * a1) >> sew,
                "vmacc": lambda: a1 * a2 + ad, "vnmsac": lambda: ad - a1 * a2,
                "vmadd": lambda: a1 * ad + a2, "vnmsub": lambda: a2 - a1 * ad,
                "vmerge": lambda: a1 if m.bget(0, i) else a2, "vmv": lambda: a1,
            }[op]()
            new[i] = res
        for i, v in new.items():
            m.eset(vd, i, sew, v)

    def compare(self):
        m, r = self.m, self.r
        op = r.choice(["vmseq", "vmsne", "vmsltu", "vmslt", "vmsleu", "vmsle", "vmsgtu", "vmsgt"])
        forms = {"vmsltu": ["vv", "vx"], "vmslt": ["vv", "vx"], "vmsgtu": ["vx", "vi"],
                 "vmsgt": ["vx", "vi"]}.get(op, ["vv", "vx", "vi"])
        form = r.choice(forms)
        vm = r.random() < 0.6
        g = m.lmul if m.lmul >= 1 else 1
        vs2, _ = self.group(g)
        vs1, _ = self.group(g)
        vd = r.randrange(1 if not vm else 0, 32)
        x, simm = r.randrange(1 << 32), r.randrange(-16, 16)
        if form == "vx":
            self.li("t1", x)
        src = {"vv": "v%d" % vs1, "vx": "t1", "vi": str(simm)}[form]
        self.emit("%s.%s v%d, v%d, %s%s" % (op, form, vd, vs2, src, "" if vm else ", v0.t"))
        sew, mask = m.sew, (1 << m.sew) - 1
        bits = {}
        for i in range(m.vl):
            if not m.active(i, vm):
                continue
            a2 = m.eget(vs2, i, sew)
            a1 = {"vv": m.eget(vs1, i, sew) if form == "vv" else 0, "vx": x & mask, "vi": simm & mask}[form]
            s2, s1 = sx(a2, sew), sx(a1, sew)
            bits[i] = int({"vmseq": a2 == a1, "vmsne": a2 != a1, "vmsltu": a2 < a1, "vmslt": s2 < s1,
                           "vmsleu": a2 <= a1, "vmsle": s2 <= s1, "vmsgtu": a2 > a1, "vmsgt": s2 > s1}[op])
        for i, b in bits.items():
            m.bset(vd, i, b)

    def reduce(self):
        m, r = self.m, self.r
        op = r.choice(["vredsum", "vredand", "vredor", "vredxor", "vredminu", "vredmin", "vredmaxu", "vredmax"])
        vm = r.random() < 0.6
        g = m.lmul if m.lmul >= 1 else 1
        vs2, _ = self.group(g)
        vd, vs1 = r.randrange(32), r.randrange(32)
        self.emit("%s.vs v%d, v%d, v%d%s" % (op, vd, vs2, vs1, "" if vm else ", v0.t"))
        if m.vl == 0:
            return
        sew = m.sew
        acc = m.eget(vs1, 0, sew)
        for i in range(m.vl):
            if not m.active(i, vm):
                continue
            e = m.eget(vs2, i, sew)
            acc = {"vredsum": lambda: (acc + e), "vredand": lambda: acc & e, "vredor": lambda: acc | e,
                   "vredxor": lambda: acc ^ e, "vredminu": lambda: min(acc, e), "vredmaxu": lambda: max(acc, e),
                   "vredmin": lambda: acc if sx(acc, sew) <= sx(e, sew) else e,
                   "vredmax": lambda: acc if sx(acc, sew) >= sx(e, sew) else e}[op]() & ((1 << sew) - 1)
        m.eset(vd, 0, sew, acc)

    def masklogic(self):
        m, r = self.m, self.r
        op = r.choice(["vmand", "vmnand", "vmandn", "vmxor", "vmor", "vmnor", "vmorn", "vmxnor"])
        vd, vs2, vs1 = r.randrange(32), r.randrange(32), r.randrange(32)
        self.emit("%s.mm v%d, v%d, v%d" % (op, vd, vs2, vs1))
        bits = {}
        for i in range(m.vl):
            a, b = m.bget(vs2, i), m.bget(vs1, i)
            bits[i] = {"vmand": a & b, "vmnand": 1 - (a & b), "vmandn": a & (1 - b), "vmxor": a ^ b,
                       "vmor": a | b, "vmnor": 1 - (a | b), "vmorn": a | (1 - b), "vmxnor": 1 - (a ^ b)}[op]
        for i, b in bits.items():
            m.bset(vd, i, b)

    def scalars(self):
        m, r = self.m, self.r
        k = r.choice(["cpop", "first", "mvxs", "mvsx", "vid"])
        vm = r.random() < 0.6
        if k in ("cpop", "first"):
            vs2 = r.randrange(32)
            self.emit("v%s.m t3, v%d%s" % ("cpop" if k == "cpop" else "first", vs2, "" if vm else ", v0.t"))
            act = [i for i in range(m.vl) if m.active(i, vm) and m.bget(vs2, i)]
            self.save_scalar("t3", len(act) if k == "cpop" else (act[0] if act else 0xFFFFFFFF))
        elif k == "mvxs":
            vs2 = r.randrange(32)
            self.emit("vmv.x.s t3, v%d" % vs2)
            self.save_scalar("t3", sx(m.eget(vs2, 0, m.sew), m.sew) & 0xFFFFFFFF)
        elif k == "mvsx":
            vd, x = r.randrange(32), r.randrange(1 << 32)
            self.li("t1", x)
            self.emit("vmv.s.x v%d, t1" % vd)
            if m.vl > 0:
                m.eset(vd, 0, m.sew, x)
        else:
            g = m.lmul if m.lmul >= 1 else 1
            vd, _ = self.group(g, not_v0=not vm)
            self.emit("vid.v v%d%s" % (vd, "" if vm else ", v0.t"))
            for i in range(m.vl):
                if m.active(i, vm):
                    m.eset(vd, i, m.sew, i)

    def slide(self):
        m, r = self.m, self.r
        k = r.choice(["up", "down", "1up", "1down"])
        vm = r.random() < 0.6
        g = m.lmul if m.lmul >= 1 else 1
        vs2, rng2 = self.group(g)
        vd, _ = self.group(g, avoid=(rng2,) if k in ("up", "1up") else (), not_v0=not vm)
        if vd is None:
            return
        sew, vlmax = m.sew, m.vlmax()
        off = r.choice([0, 1, 2, r.randrange(vlmax + 2)])
        x = r.randrange(1 << 32)
        msk = "" if vm else ", v0.t"
        old = {i: m.eget(vs2, i, sew) for i in range(vlmax)}
        res = {}
        if k == "up":
            if off < 32 and r.random() < 0.5:
                self.emit("vslideup.vi v%d, v%d, %d%s" % (vd, vs2, off, msk))
            else:
                self.li("t1", off); self.emit("vslideup.vx v%d, v%d, t1%s" % (vd, vs2, msk))
            for i in range(off, m.vl):
                if m.active(i, vm):
                    res[i] = old[i - off]
        elif k == "down":
            if off < 32 and r.random() < 0.5:
                self.emit("vslidedown.vi v%d, v%d, %d%s" % (vd, vs2, off, msk))
            else:
                self.li("t1", off); self.emit("vslidedown.vx v%d, v%d, t1%s" % (vd, vs2, msk))
            for i in range(m.vl):
                if m.active(i, vm):
                    res[i] = old[i + off] if i + off < vlmax else 0
        elif k == "1up":
            self.li("t1", x); self.emit("vslide1up.vx v%d, v%d, t1%s" % (vd, vs2, msk))
            for i in range(m.vl):
                if m.active(i, vm):
                    res[i] = x if i == 0 else old[i - 1]
        else:
            self.li("t1", x); self.emit("vslide1down.vx v%d, v%d, t1%s" % (vd, vs2, msk))
            for i in range(m.vl):
                if m.active(i, vm):
                    res[i] = x if i == m.vl - 1 else old[i + 1]
        for i, v in res.items():
            m.eset(vd, i, sew, v)

    def movnr(self):
        m, r = self.m, self.r
        n = r.choice([1, 2, 4, 8])
        vd, vs2 = r.randrange(0, 32, n), r.randrange(0, 32, n)
        self.emit("vmv%dr.v v%d, v%d" % (n, vd, vs2))
        src = bytes(m.v[vs2 * m.vlenb:(vs2 + n) * m.vlenb])
        m.v[vd * m.vlenb:(vd + n) * m.vlenb] = src

    def memop(self):
        m, r = self.m, self.r
        kind = r.choice(["unit", "unit", "stride", "index", "mask", "whole", "ff"])
        store = r.random() < 0.45 and kind != "ff"
        vm = r.random() < 0.6 if kind in ("unit", "stride", "index", "ff") else True
        sew, vl = m.sew, m.vl
        base = DATA + 4 * r.randrange(0, 256)          # DATA .. DATA+1 KiB
        self.li("a0", base)
        if kind in ("unit", "stride", "ff"):
            eew = r.choice([8, 16, 32])
            ok, emul = emul_ok(eew, sew, m.lmul)
            if not ok:
                return
            vd, _ = self.group(emul if emul >= 1 else 1, not_v0=not vm and not store)
            if vd is None:
                return
            msk = "" if vm else ", v0.t"
            if kind == "stride":
                stride = (eew // 8) * r.randrange(0, 5)
                self.li("a1", stride)
                self.emit("%s%d.v v%d, (a0), a1%s" % ("vsse" if store else "vlse", eew, vd, msk))
            else:
                stride = eew // 8
                self.emit("%s%d%s.v v%d, (a0)%s" % ("vse" if store else "vle", eew,
                                                   "ff" if kind == "ff" else "", vd, msk))
            for i in range(vl):
                if not m.active(i, vm):
                    continue
                a = base + i * stride
                if store:
                    m.mset(a, eew // 8, m.eget(vd, i, eew))
                else:
                    m.eset(vd, i, eew, m.mget(a, eew // 8))
        elif kind == "index":
            ieew = r.choice([8, 16, 32])
            ok, iemul = emul_ok(ieew, sew, m.lmul)
            if not ok:
                return
            g = m.lmul if m.lmul >= 1 else 1
            vix, rngi = self.group(iemul if iemul >= 1 else 1)
            self.li("a2", self.idx_tab[ieew])
            self.emit("vl%dre%d.v v%d, (a2)" % (max(1, int(iemul)), ieew, vix))  # load index regs
            nb = max(1, int(iemul)) * m.vlenb
            m.v[vix * m.vlenb:vix * m.vlenb + nb] = m.mem[self.idx_tab[ieew]:self.idx_tab[ieew] + nb]
            vd, _ = self.group(g, avoid=(rngi,), not_v0=not vm and not store)
            if vd is None:
                return
            op = r.choice(["u", "o"])
            self.emit("v%s%sxei%d.v v%d, (a0), v%d%s" % ("s" if store else "l", op, ieew, vd, vix,
                                                      "" if vm else ", v0.t"))
            for i in range(vl):
                if not m.active(i, vm):
                    continue
                a = base + m.eget(vix, i, ieew)
                if store:
                    m.mset(a, sew // 8, m.eget(vd, i, sew))
                else:
                    m.eset(vd, i, sew, m.mget(a, sew // 8))
        elif kind == "mask":
            vd = r.randrange(32)
            self.emit("%s.v v%d, (a0)" % ("vsm" if store else "vlm", vd))
            for i in range((vl + 7) // 8):
                if store:
                    m.mset(base + i, 1, m.v[vd * m.vlenb + i])
                else:
                    m.v[vd * m.vlenb + i] = m.mem[base + i]
        else:
            n = r.choice([1, 2, 4, 8])
            vd = r.randrange(0, 32, n)
            if store:
                self.emit("vs%dr.v v%d, (a0)" % (n, vd))
                m.mem[base:base + n * m.vlenb] = m.v[vd * m.vlenb:(vd + n) * m.vlenb]
            else:
                self.emit("vl%dre%d.v v%d, (a0)" % (n, r.choice([8, 16, 32]), vd))
                m.v[vd * m.vlenb:(vd + n) * m.vlenb] = m.mem[base:base + n * m.vlenb]

    def build(self):
        m = self.m
        self.asm += ["    .section .text.init", "    .globl _start", "_start:",
                     "    li t0, 0x200", "    csrs mstatus, t0          # mstatus.VS = Initial",
                     "    li s1, %d" % OUT_S]
        # fill every vector register from the random data
        for reg in range(0, 32, 8):
            self.li("a0", DATA + reg * m.vlenb)
            self.emit("vl8re32.v v%d, (a0)" % reg)
        m.v[:] = m.mem[DATA:DATA + 32 * m.vlenb]
        self.vset()
        kinds = [self.vset, self.arith, self.arith, self.arith, self.compare, self.reduce,
                 self.masklogic, self.scalars, self.slide, self.movnr, self.memop, self.memop]
        for _ in range(self.count):
            self.r.choice(kinds)()
        for reg in range(32):
            self.li("a0", OUT_V + reg * m.vlenb)
            self.emit("vs1r.v v%d, (a0)" % reg)
        m.mem[OUT_V:OUT_V + 32 * m.vlenb] = m.v
        self.asm += ["    li t0, 0x20000000", "    sw zero, 0(t0)", "1:  j 1b"]
        # the random data and index tables, placed by the linker script
        data = ["    .section .vdata, \"aw\""]
        for a in range(DATA, OUT_V, 4):
            data.append("    .word 0x%08x" % int.from_bytes(self.init[a:a + 4], "little"))
        return "\n".join(self.asm + data) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--count", type=int, default=60)
    ap.add_argument("--vlen", type=int, default=128)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    g = Gen(a.seed, a.count, a.vlen)
    text = g.build()
    os.makedirs(a.out, exist_ok=True)
    open(os.path.join(a.out, "prog.S"), "w").write(text)
    with open(os.path.join(a.out, "expect.hex"), "w") as f:
        for x in range(DATA, END, 4):
            f.write("%08x\n" % int.from_bytes(g.m.mem[x:x + 4], "little"))


if __name__ == "__main__":
    main()
