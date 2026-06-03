// =====================================================================
// bram_rom.v  -  Synchronous-read instruction ROM (infers block RAM)
// ---------------------------------------------------------------------
// Word-addressed, registered read: the instruction at `addr_word` is
// valid ONE cycle after the address is presented. A registered read is
// what lets Vivado/XST map this to a block RAM (BRAM) instead of LUTs.
// Initialized from a hex image (one 32-bit word per line).
// =====================================================================
`default_nettype none

module bram_rom #(
    parameter WORDS = 1024,
    parameter INIT_FILE = ""
) (
    input  wire                       clk,
    input  wire [$clog2(WORDS)-1:0]   addr_word,
    output reg  [31:0]                rdata
);
    reg [31:0] mem [0:WORDS-1];
    integer i;
    initial begin
        for (i = 0; i < WORDS; i = i + 1) mem[i] = 32'd0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end
    always @(posedge clk) rdata <= mem[addr_word];   // registered read => BRAM
endmodule

`default_nettype wire
