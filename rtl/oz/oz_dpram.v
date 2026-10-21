// =====================================================================
// oz_dpram.v  -  dual-port block RAM (two ports, one clock)
// ---------------------------------------------------------------------
// The memory behind every OpenZynq RISC-V SoC (Step 45). Port A belongs to
// the core (or its cache refill engine): byte-lane writes, registered
// read. Port B belongs to the host -- in PS-attached builds the Cortex-A9
// loads the program through it over M_AXI_GP0 while the core is held in
// reset (oz_host brings those writes into this clock domain first).
//
// Both ports share the core clock on purpose. A RAMB36 could clock its
// ports separately, but Yosys only infers a true dual-port block RAM from
// a single-clock description in some versions (0.33 rejects two clocks),
// and one clock keeps the memory version-proof.
//
// Written in the two-process template that Yosys (synth_xilinx) and
// Vivado both map to block RAM. INIT_FILE preloads it ($readmemh, one
// 32-bit word per line), which is how standalone builds carry firmware
// inside the bitstream.
// =====================================================================
`default_nettype none

module oz_dpram #(
    parameter WORDS     = 4096,
    parameter INIT_FILE = ""
) (
    input  wire                     clk,
    // ---- port A (core) ----
    input  wire                     en_a,
    input  wire [3:0]               we_a,
    input  wire [$clog2(WORDS)-1:0] addr_a,
    input  wire [31:0]              wdata_a,
    output reg  [31:0]              rdata_a,
    // ---- port B (host) ----
    input  wire                     en_b,
    input  wire [3:0]               we_b,
    input  wire [$clog2(WORDS)-1:0] addr_b,
    input  wire [31:0]              wdata_b,
    output reg  [31:0]              rdata_b
);
    reg [31:0] mem [0:WORDS-1];
    integer k;
    initial begin
        for (k = 0; k < WORDS; k = k + 1) mem[k] = 32'd0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    always @(posedge clk) if (en_a) begin
        if (we_a[0]) mem[addr_a][7:0]   <= wdata_a[7:0];
        if (we_a[1]) mem[addr_a][15:8]  <= wdata_a[15:8];
        if (we_a[2]) mem[addr_a][23:16] <= wdata_a[23:16];
        if (we_a[3]) mem[addr_a][31:24] <= wdata_a[31:24];
        rdata_a <= mem[addr_a];
    end

    always @(posedge clk) if (en_b) begin
        if (we_b[0]) mem[addr_b][7:0]   <= wdata_b[7:0];
        if (we_b[1]) mem[addr_b][15:8]  <= wdata_b[15:8];
        if (we_b[2]) mem[addr_b][23:16] <= wdata_b[23:16];
        if (we_b[3]) mem[addr_b][31:24] <= wdata_b[31:24];
        rdata_b <= mem[addr_b];
    end
endmodule

`default_nettype wire
