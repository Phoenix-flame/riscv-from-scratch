# =====================================================================
# build.tcl  -  ISE 14.7 project script: RTL -> s6_top.bit
# ---------------------------------------------------------------------
# Run it with ISE's Tcl shell, from spartan6/syn:
#
#     source /opt/Xilinx/14.7/ISE_DS/settings64.sh
#     cd spartan6/syn
#     xtclsh build.tcl
#
# or, to open the generated project in the GUI afterwards:
#
#     xtclsh build.tcl && ise s6_top.xise &
#
# Everything the flow needs is created from scratch, so the project file
# is disposable: delete s6_top.xise and re-run to get a clean build. The
# equivalent headless flow (xst/ngdbuild/map/par/bitgen invoked directly,
# no project file at all) is build_ise.sh next to this script.
#
# The block RAM is initialised from ../sw/firmware.hex at synthesis time,
# so build the firmware BEFORE running this:  ../sw/build.sh
# =====================================================================

set proj    "s6_top"
set top     "s6_top"
set device  "xc6slx9"
set package "tqg144"
set speed   "-2"
set family  "spartan6"

# ---- sources, in dependency-free order (XST does not care) -----------
set sources {
    ../rtl/s6_regfile.v
    ../rtl/s6_rvc.v
    ../rtl/s6_muldiv.v
    ../rtl/s6_csr.v
    ../rtl/s6_core.v
    ../rtl/s6_ram.v
    ../rtl/s6_fifo.v
    ../rtl/s6_uart_tx.v
    ../rtl/s6_uart_rx.v
    ../rtl/s6_uart.v
    ../rtl/s6_clint.v
    ../rtl/s6_gpio.v
    ../rtl/s6_sram.v
    ../rtl/s6_soc.v
    ../rtl/s6_clkgen.v
    ../rtl/s6_top.v
}
set ucf ../constraints/posedge_one_lx9.ucf

# ---------------------------------------------------------------------
puts "\n== creating project $proj.xise =="
if {[file exists $proj.xise]} { file delete -force $proj.xise }
project new $proj.xise

project set family  $family
project set device  $device
project set package $package
project set speed   $speed
project set top_level_module_type "HDL"
project set synthesis_tool "XST (VHDL/Verilog)"
project set simulator      "ISim (VHDL/Verilog)"
project set "Preferred Language" "Verilog"
project set "Enable Message Filtering" false

foreach f $sources { xfile add $f }
xfile add $ucf
project set top $top

# ---- synthesis -------------------------------------------------------
# The core is a multi-cycle machine with a long combinational EXEC path,
# so XST is told to optimise for speed and to keep the hierarchy flat
# enough that it can retime across the module boundaries.
project set "Optimization Goal"   "Speed" -process "Synthesize - XST"
project set "Optimization Effort" "High"  -process "Synthesize - XST"
project set "Keep Hierarchy"      "No"    -process "Synthesize - XST"
project set "Register Balancing"  "Yes"   -process "Synthesize - XST"
project set "Verilog Macros" "SYNTHESIS"  -process "Synthesize - XST"
# Let XST pick block RAM for s6_ram and distributed RAM for the register
# file and the FIFOs; both inferences are already written to match.
project set "RAM Style"  "Auto" -process "Synthesize - XST"
project set "ROM Style"  "Auto" -process "Synthesize - XST"
project set "Use DSP Block" "Auto" -process "Synthesize - XST"

# ---- implementation --------------------------------------------------
project set "Pack I/O Registers into IOBs" "For Inputs and Outputs" \
        -process "Map"
project set "Place & Route Effort Level (Overall)" "High" -process "Map"
project set "Perform Timing-Driven Packing and Placement" true -process "Map"
project set "Extra Effort (Highest PAR level only)" "Normal" \
        -process "Place & Route"

# ---- bitstream -------------------------------------------------------
# A .bin as well as the .bit: xc3sprog and openFPGALoader are happy with
# either, but SPI-flash tools generally want the raw .bin.
project set "Create Binary Configuration File" true \
        -process "Generate Programming File"
project set "Unused IOB Pins" "Pull Down" -process "Generate Programming File"
project set "Configuration Rate" "26" -process "Generate Programming File"

puts "\n== running the flow (synthesise -> translate -> map -> par -> bitgen) =="
if {[catch {process run "Generate Programming File" -force rerun_all} msg]} {
    puts "FLOW FAILED: $msg"
    project close
    exit 1
}

# ---- report ----------------------------------------------------------
puts "\n== done =="
foreach r {s6_top.syr s6_top_map.mrp s6_top.par s6_top.twr} {
    if {[file exists $r]} { puts "  report: [pwd]/$r" }
}
if {[file exists $proj.bit]} {
    puts "  bitstream: [pwd]/$proj.bit"
} else {
    puts "  NO BITSTREAM PRODUCED - read the reports above"
}
project close
