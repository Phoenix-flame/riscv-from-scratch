#!/usr/bin/env bash
# =====================================================================
# build_ise.sh  -  headless ISE 14.7 flow: RTL -> s6_top.bit
# ---------------------------------------------------------------------
# No project file: xst, ngdbuild, map, par, trce and bitgen are invoked
# directly, which is the flow you want in a Makefile or in CI. The Tcl
# project equivalent (for people who then want the GUI) is build.tcl.
#
#     source /opt/Xilinx/14.7/ISE_DS/settings64.sh
#     ../sw/build.sh          # the .hex the block RAM is initialised with
#     ./build_ise.sh
#
# Outputs, all in this directory:
#     s6_top.bit / s6_top.bin   the bitstream
#     s6_top.syr                synthesis report (area: LUTs, FFs, BRAMs)
#     s6_top_map.mrp            packed utilisation
#     s6_top.twr                timing: does it make the clock or not
# =====================================================================
set -e

cd "$(dirname "$0")"

PART=xc6slx9-2-tqg144
TOP=s6_top
UCF=../constraints/posedge_one_lx9.ucf

command -v xst >/dev/null 2>&1 || {
    echo "xst not found -- source the ISE settings script first, e.g."
    echo "    source /opt/Xilinx/14.7/ISE_DS/settings64.sh"
    exit 1
}

if [ ! -f ../sw/firmware.hex ]; then
    echo "../sw/firmware.hex is missing -- run ../sw/build.sh first"
    exit 1
fi

# On a shared folder (the repo mounted from a Windows host, say) the
# directories themselves can be held open -- 'Text file busy' -- while
# their contents still delete fine. That is enough for a clean run.
if ! rm -rf xst _ngo netlist.lst 2>/dev/null; then
    echo "note: could not remove xst/ _ngo/ -- emptying them instead"
    rm -rf xst/* xst/.[!.]* _ngo/* _ngo/.[!.]* netlist.lst 2>/dev/null || true
fi
mkdir -p xst/projnav.tmp

echo "== synthesise =="
xst -intstyle ise -ifn "$TOP.xst" -ofn "$TOP.syr"

echo "== translate =="
ngdbuild -intstyle ise -dd _ngo -nt timestamp -uc "$UCF" \
         -p "$PART" "$TOP.ngc" "$TOP.ngd"

echo "== map =="
map -intstyle ise -p "$PART" -w -logic_opt off -ol high -t 1 \
    -xt 0 -register_duplication off -r 4 -global_opt off -mt off -ir off \
    -pr b -lc off -power off -o "${TOP}_map.ncd" "$TOP.ngd" "$TOP.pcf"

echo "== place & route =="
par -w -intstyle ise -ol high -mt off "${TOP}_map.ncd" "$TOP.ncd" "$TOP.pcf"

echo "== timing =="
trce -intstyle ise -v 12 -s 2 -n 12 -fastpaths -xml "$TOP.twx" \
     "$TOP.ncd" -o "$TOP.twr" "$TOP.pcf" || true

echo "== bitgen =="
bitgen -intstyle ise -f "$TOP.ut" "$TOP.ncd"

echo
echo "bitstream: $(pwd)/$TOP.bit"
echo
grep -E "Number of Slice|Number of RAMB|Number of DSP|Maximum Frequency" \
     "$TOP.syr" 2>/dev/null || true
grep -E "All constraints were met|constraints? (was|were) not met|Minimum period" \
     "$TOP.twr" 2>/dev/null || true
