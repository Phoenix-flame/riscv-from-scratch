// =====================================================================
// bram_ram.v  -  Synchronous-read data RAM with byte write enables
// ---------------------------------------------------------------------
// Word-addressed (32-bit) with a 4-bit byte-write mask. Registered read
// (1-cycle latency) so it infers as a block RAM. This is the canonical
// Xilinx byte-write BRAM template. Sub-word load/store alignment is done
// in the CPU (it forms the write mask and extracts loaded bytes).
// =====================================================================
`default_nettype none

module bram_ram #(
    parameter WORDS = 2048,
    parameter INIT_FILE = ""
) (
    input  wire                       clk,
    input  wire [$clog2(WORDS)-1:0]   addr_word,
    input  wire [3:0]                 we,        // per-byte write enable
    input  wire [31:0]                wdata,
    output reg  [31:0]                rdata
);
    reg [31:0] mem [0:WORDS-1];
    integer i;
    initial begin
        for (i = 0; i < WORDS; i = i + 1) mem[i] = 32'd0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end
    always @(posedge clk) begin
        if (we[0]) mem[addr_word][ 7: 0] <= wdata[ 7: 0];
        if (we[1]) mem[addr_word][15: 8] <= wdata[15: 8];
        if (we[2]) mem[addr_word][23:16] <= wdata[23:16];
        if (we[3]) mem[addr_word][31:24] <= wdata[31:24];
        rdata <= mem[addr_word];                 // registered read => BRAM
    end
endmodule

`default_nettype wire
