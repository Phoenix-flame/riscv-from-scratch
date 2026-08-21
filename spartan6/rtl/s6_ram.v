// =====================================================================
// s6_ram.v  -  Unified code+data memory: true dual-port block RAM
// ---------------------------------------------------------------------
// Port A is the instruction fetch port (read only), port B is the data
// port (byte writes). One array serves both, so there is a single flat
// address space: code, .rodata, .data, .bss, stack and heap all live in
// the same memory and the linker script does not have to split them.
//
// This is the canonical Xilinx true-dual-port byte-write template. On
// Spartan-6 XST maps it to RAMB16BWER primitives in 512x36 mode, so the
// default 4096 words (16 KB) costs 8 of the LX9's 32 block RAMs.
//
// Both reads are registered -- one cycle of latency -- which is exactly
// what the core's FETCH/EXEC and EXEC/LOAD pairs are built around.
// =====================================================================
`default_nettype none

module s6_ram #(
    parameter WORDS     = 4096,
    parameter INIT_FILE = "",
    // AW = log2(WORDS), derived from it -- never override at instantiation.
    // ISE's XST rejects $clog2 in declarations, so the ladder below does
    // the same job as a constant expression every Verilog-2001 tool takes.
    parameter AW = (WORDS<=256)    ?  8 : (WORDS<=512)    ?  9 :
                   (WORDS<=1024)   ? 10 : (WORDS<=2048)   ? 11 :
                   (WORDS<=4096)   ? 12 : (WORDS<=8192)   ? 13 :
                   (WORDS<=16384)  ? 14 : (WORDS<=32768)  ? 15 :
                   (WORDS<=65536)  ? 16 : (WORDS<=131072) ? 17 : 18
) (
    input  wire                      clk,
    // port A: instruction fetch
    input  wire [AW-1:0]             a_addr,
    output reg  [31:0]               a_rdata,
    // port B: data
    input  wire [AW-1:0]             b_addr,
    input  wire [3:0]                b_we,
    input  wire [31:0]               b_wdata,
    output reg  [31:0]               b_rdata
);
    reg [31:0] mem [0:WORDS-1];

    integer i;
    initial begin
        for (i = 0; i < WORDS; i = i + 1) mem[i] = 32'd0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    always @(posedge clk)
        a_rdata <= mem[a_addr];

    always @(posedge clk) begin
        if (b_we[0]) mem[b_addr][ 7: 0] <= b_wdata[ 7: 0];
        if (b_we[1]) mem[b_addr][15: 8] <= b_wdata[15: 8];
        if (b_we[2]) mem[b_addr][23:16] <= b_wdata[23:16];
        if (b_we[3]) mem[b_addr][31:24] <= b_wdata[31:24];
        b_rdata <= mem[b_addr];
    end
endmodule

`default_nettype wire
