// =====================================================================
// syscon.v  -  System controller (simulation halt device)
// ---------------------------------------------------------------------
// A store to this device stops the simulation cleanly, with the stored
// value used as an exit code. This frees testbenches from guessing a
// fixed cycle count -- the program decides when it's done.
// (Simulation-only behavior; real hardware has no $finish.)
// =====================================================================
`default_nettype none

module syscon (
    input  wire        clk,
    input  wire        sel,
    input  wire        we,
    input  wire [31:0] wdata
);
    always @(posedge clk) begin
        if (sel && we) begin
            $display("\n[syscon] halt requested, exit code = %0d", wdata);
            $finish;
        end
    end
endmodule

`default_nettype wire
