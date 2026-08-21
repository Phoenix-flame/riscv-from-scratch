// =====================================================================
// s6_clkgen.v  -  Spartan-6 PLL: 24 MHz board clock -> SoC clock
// ---------------------------------------------------------------------
// The Posedge One's oscillator is 24 MHz, which is slower than the core
// wants and awkward for baud rates. PLL_BASE multiplies it up:
//
//     f_vco = 24 MHz * MULT / DIVCLK      (must land in 400..1080 MHz)
//     f_out = f_vco / DIV
//
// The defaults are MULT=32, DIVCLK=1, DIV=48 -> VCO 768 MHz, out 16 MHz.
//
// 16 MHz because that is what the design actually closes at. The EXEC
// path runs from the block RAM's data output, through the RVC
// decompressor, the decoder, the ALU and the address compare, and back
// into the block RAM's address port -- all in one cycle, 47.1 ns of it
// (see syn/s6_top.twr, "Minimum period"). At the old DIV=16 (48 MHz)
// that path missed its 20.8 ns requirement by -26 ns on 3916 endpoints,
// and the SoC did not run at all: no boot banner, no UART, nothing.
// Raise the clock only once that path is split across two cycles.
//
// Whatever you pick, change CLK_HZ on s6_soc to match, or the UART baud
// divisor and the CLINT microsecond tick will both be wrong.
//
// `locked` holds the SoC in reset until the PLL has settled.
//
// This file instantiates a Xilinx primitive, so it is only compiled by
// the ISE flow. Simulation uses tb/s6_clkgen_sim.v, which has the same
// port list and just divides/multiplies behaviourally.
// =====================================================================
`default_nettype none

module s6_clkgen #(
    parameter real    CLKIN_PERIOD_NS = 41.667,   // 24 MHz
    parameter integer MULT            = 32,
    parameter integer DIVCLK          = 1,
    parameter integer DIV             = 48
) (
    input  wire clk_in,
    output wire clk_out,
    output wire locked
);
    wire clk_fb, clk_out_raw;

    PLL_BASE #(
        .BANDWIDTH          ("OPTIMIZED"),
        .CLK_FEEDBACK       ("CLKFBOUT"),
        .COMPENSATION       ("INTERNAL"),
        .DIVCLK_DIVIDE      (DIVCLK),
        .CLKFBOUT_MULT      (MULT),
        .CLKFBOUT_PHASE     (0.0),
        .CLKIN_PERIOD       (CLKIN_PERIOD_NS),
        .CLKOUT0_DIVIDE     (DIV),
        .CLKOUT0_DUTY_CYCLE (0.5),
        .CLKOUT0_PHASE      (0.0),
        .REF_JITTER         (0.010)
    ) u_pll (
        .CLKFBOUT (clk_fb),
        .CLKOUT0  (clk_out_raw),
        .CLKOUT1  (), .CLKOUT2 (), .CLKOUT3 (), .CLKOUT4 (), .CLKOUT5 (),
        .LOCKED   (locked),
        .CLKFBIN  (clk_fb),
        .CLKIN    (clk_in),
        .RST      (1'b0)
    );

    BUFG u_bufg (.I(clk_out_raw), .O(clk_out));
endmodule

`default_nettype wire
