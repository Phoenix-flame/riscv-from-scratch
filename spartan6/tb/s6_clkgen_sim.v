// =====================================================================
// s6_clkgen_sim.v  -  simulation stand-in for rtl/s6_clkgen.v
// ---------------------------------------------------------------------
// Same module name and port list as the real one, but it generates the
// output clock behaviourally instead of instantiating PLL_BASE, which
// iverilog has no model for. Swapping this in is what lets the FPGA top
// (rtl/s6_top.v) be elaborated and simulated at all -- otherwise the only
// thing that ever checks s6_top is ISE, and a mistyped port there is not
// found until synthesis.
//
// Compile this INSTEAD OF rtl/s6_clkgen.v; never both.
// =====================================================================
`timescale 1ns/1ps
`default_nettype none

module s6_clkgen #(
    parameter real    CLKIN_PERIOD_NS = 41.667,   // 24 MHz
    parameter integer MULT            = 32,
    parameter integer DIVCLK          = 1,
    parameter integer DIV             = 16
) (
    input  wire clk_in,
    output reg  clk_out,
    output reg  locked
);
    // f_out = f_in * MULT / (DIVCLK * DIV)  =>  the period scales the other way
    localparam real OUT_PERIOD = (CLKIN_PERIOD_NS * DIVCLK * DIV) / MULT;

    initial begin
        clk_out = 1'b0;
        locked  = 1'b0;
        #(CLKIN_PERIOD_NS * 20.0) locked = 1'b1;   // pretend lock time
    end

    always #(OUT_PERIOD / 2.0) clk_out = ~clk_out;

    // clk_in is unused here on purpose; keep the tools quiet about it.
    wire _unused = &{1'b0, clk_in};
endmodule

`default_nettype wire
