// =====================================================================
// s6_sram_model.v  -  behavioural IS61WV5128BLL (512K x 8 async SRAM)
// ---------------------------------------------------------------------
// Simulation only. Models the part the Posedge One actually carries:
//
//   * asynchronous read: data appears TAA ns after the address (or after
//     /CE and /OE go low), and goes high-Z when either is deasserted
//   * write terminated by the rising edge of /WE with /CE low, latching
//     whatever the address and data lines hold at that instant
//   * timing assertions for tWP (write pulse width) and tDW (data setup),
//     so a controller that clocks the part too fast fails here rather
//     than on the bench
//
// Defaults are the -10 speed grade (tAA 10 ns, tWP 8 ns, tDW 6 ns).
// =====================================================================
`timescale 1ns/1ps

module s6_sram_model #(
    parameter ADDR_BITS = 19,
    parameter real TAA  = 10.0,        // address access time
    parameter real TWP  = 8.0,         // write pulse width
    parameter real TDW  = 6.0          // data setup to end of write
) (
    input  wire [ADDR_BITS-1:0] a,
    inout  wire [7:0]           d,
    input  wire                 ce_n,
    input  wire                 oe_n,
    input  wire                 we_n
);
    reg [7:0] mem [0:(1<<ADDR_BITS)-1];

    integer i;
    initial for (i = 0; i < (1 << ADDR_BITS); i = i + 1) mem[i] = 8'h00;

    // ---- read path ----
    // Read through a continuous assignment, NOT `always @(*) x = mem[a];`.
    // An implicit sensitivity list over a 512 K-entry array makes iverilog
    // build one event trigger per element at compile time, which takes
    // minutes and gigabytes. A continuous assign reads the array directly.
    wire drive = ~ce_n & ~oe_n & we_n;
    assign #(TAA) d = drive ? mem[a] : 8'bz;

    // ---- write path: latch on the rising edge of /WE ----
    real we_fell, d_changed;
    initial begin we_fell = 0.0; d_changed = 0.0; end

    always @(negedge we_n) if (!ce_n) we_fell = $realtime;
    always @(d)            d_changed = $realtime;

    always @(posedge we_n) if (!ce_n) begin
        if (($realtime - we_fell) < TWP)
            $display("[sram] %0t WARNING: /WE low for %0.1f ns, tWP is %0.1f ns",
                     $time, $realtime - we_fell, TWP);
        if (($realtime - d_changed) < TDW)
            $display("[sram] %0t WARNING: data settled %0.1f ns before /WE rose (tDW %0.1f ns)",
                     $time, $realtime - d_changed, TDW);
        mem[a] <= d;
    end
endmodule
