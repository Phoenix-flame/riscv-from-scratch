// =====================================================================
// imem.v  -  Instruction memory (read-only) for RV32I
// ---------------------------------------------------------------------
// Holds the program. The PC supplies a BYTE address; instructions are
// 32-bit words on 4-byte boundaries, so the word index is addr >> 2.
// Reads are combinational (the fetch must happen within the cycle).
//
// The program is loaded at time 0 from a hex file via $readmemh, where
// each line is one 32-bit instruction in hexadecimal. That same hex
// file is how we will load real assembled programs in Step 08.
// =====================================================================
`default_nettype none

module imem #(
    parameter WORDS = 256,            // capacity in 32-bit words
    parameter INIT_FILE = ""          // hex file to preload (optional)
) (
    input  wire [31:0] addr,          // byte address (the PC)
    output wire [31:0] instr          // 32-bit instruction at that address
);
    localparam IDX = $clog2(WORDS);   // bits needed to index the array

    reg [31:0] mem [0:WORDS-1];

    integer i;
    initial begin
        // Start cleared so unused locations read as 0 (= an all-zero word).
        for (i = 0; i < WORDS; i = i + 1) mem[i] = 32'd0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    // byte address -> word index: drop the low 2 bits, keep IDX bits.
    wire [IDX-1:0] word_index = addr[IDX+1:2];
    assign instr = mem[word_index];

endmodule

`default_nettype wire
