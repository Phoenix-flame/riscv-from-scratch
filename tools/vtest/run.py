#!/usr/bin/env python3
"""run.py - random differential test of rtl/vec_unit.v against vgen's model.

    python3 tools/vtest/run.py [--seeds 0-49] [--count 60] [-j N] [--keep]

For each seed: generate (vgen.py), assemble for rv32ima_zicsr_zve32x, run on
soc_pipe_u (tb/vec_diff_tb.v), compare memory with the model. A mismatch
prints the first differing words, keyed to the region (data, vector-register
dump, scalar results) they fall in.
"""
import argparse
import concurrent.futures
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
BUILD = REPO / "build" / "vtest"
RTL = ["alu", "regfile", "immgen", "control", "csr_s", "branch_predictor", "bpred_b", "timer", "uart_tx",
       "uart_hw", "tlb", "ptw", "zb_unit", "vec_unit", "cpu_pipe_u", "soc_pipe_u"]   # last: the SoC
sys.path.insert(0, str(Path(__file__).parent))
import vgen  # noqa: E402


def sh(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw)


def region(a, vlenb):
    if a < vgen.OUT_V:
        return "data+0x%x" % (a - vgen.DATA)
    if a < vgen.OUT_S:
        return "v%d byte %d" % ((a - vgen.OUT_V) // vlenb, (a - vgen.OUT_V) % vlenb)
    return "scalar #%d" % ((a - vgen.OUT_S) // 4)


def one(seed, count, vvp, vlen):
    d = BUILD / ("v%d_s%d" % (vlen, seed))
    sh([sys.executable, str(Path(__file__).parent / "vgen.py"), "--seed", str(seed),
        "--count", str(count), "--vlen", str(vlen), "--out", str(d)])
    sh(["riscv64-unknown-elf-gcc", "-march=rv32ima_zicsr_zve32x", "-mabi=ilp32", "-nostdlib",
        "-nostartfiles", "-T", str(Path(__file__).parent / "link.ld"), str(d / "prog.S"),
        "-o", str(d / "prog.elf")])
    sh(["riscv64-unknown-elf-objcopy", "-O", "binary", str(d / "prog.elf"), str(d / "prog.bin")])
    hexp = d / "prog.hex"
    hexp.write_text(sh([sys.executable, str(REPO / "sw" / "bin2hex.py"), str(d / "prog.bin")]).stdout)
    out = sh(["vvp", "-n", str(vvp), "+ROM=%s" % hexp, "+DUMP=%s" % (d / "got.hex")]).stdout
    if "halted" not in out:
        return seed, False, out.strip()
    got = (d / "got.hex").read_text().split()
    exp = (d / "expect.hex").read_text().split()
    bad = [(vgen.DATA + 4 * i, g, e) for i, (g, e) in enumerate(zip(got, exp)) if g != e]
    if not bad:
        return seed, True, out.strip().split("\n")[-1]
    msg = ["%d mismatching words" % len(bad)]
    for a, g, e in bad[:8]:
        msg.append("  0x%04x %-18s got %s want %s" % (a, region(a, vlen // 8), g, e))
    return seed, False, "\n".join(msg)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", default="0-49")
    ap.add_argument("--count", type=int, default=60)
    ap.add_argument("--vlen", type=int, default=128, choices=[64, 128, 256])
    ap.add_argument("--cached", action="store_true",
                    help="run on soc_pipe_c: I/D caches over slow memory")
    ap.add_argument("-j", type=int, default=os.cpu_count())
    ap.add_argument("--bisect", type=int, metavar="SEED",
                    help="find the shortest failing prefix of SEED's program")
    a = ap.parse_args()
    lo, _, hi = a.seeds.partition("-")
    seeds = range(int(lo), int(hi or lo) + 1)
    BUILD.mkdir(parents=True, exist_ok=True)
    vvp = BUILD / ("vec_diff_tb_%d%s.vvp" % (a.vlen, "c" if a.cached else ""))
    rtl = RTL[:-1] + (["mem_slow", "icache", "dcache", "mem_bridge", "soc_pipe_c"] if a.cached else ["soc_pipe_u"])
    sh(["iverilog", "-g2012", "-Pvec_diff_tb.VLEN=%d" % a.vlen, "-o", str(vvp)]
       + (["-DCACHED"] if a.cached else []) + [str(REPO / "rtl" / (f + ".v")) for f in rtl]
       + [str(REPO / "tb" / "vec_diff_tb.v")])
    if a.bisect is not None:
        # instruction k is generated the same way whatever --count is, so
        # the shortest failing count names the first bad instruction
        lo, hi = 0, a.count
        while lo < hi:
            mid = (lo + hi) // 2
            if one(a.bisect, mid, vvp, a.vlen)[1]:
                lo = mid + 1
            else:
                hi = mid
        _, ok, msg = one(a.bisect, lo, vvp, a.vlen)
        print("seed %d first fails with --count %d\n%s\nprogram: %s" %
              (a.bisect, lo, msg, BUILD / ("v%d_s%d" % (a.vlen, a.bisect)) / "prog.S"))
        return
    fails = 0
    with concurrent.futures.ThreadPoolExecutor(a.j) as ex:
        for seed, ok, msg in ex.map(lambda s: one(s, a.count, vvp, a.vlen), seeds):
            if not ok:
                fails += 1
                print("seed %d: FAIL\n%s" % (seed, msg))
    n = len(seeds)
    print("VTEST: %d/%d seeds pass (%d instructions each, VLEN=%d%s)" %
          (n - fails, n, a.count, a.vlen, ", caches + slow memory" if a.cached else ""))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
