// =====================================================================
// dmem.v  -  Data memory for RV32I loads and stores
// ---------------------------------------------------------------------
// Byte-addressable, little-endian (the byte at the lowest address is
// the least significant). Reads are combinational; writes are clocked.
// Supports the full RV32I load/store width set, selected by funct3:
//
//   loads  : 000 LB  001 LH  010 LW  100 LBU  101 LHU
//   stores : 000 SB  001 SH  010 SW
//
// (Aligned accesses are assumed, as RV32I requires.)
// =====================================================================
`default_nettype none

module dmem #(
    parameter BYTES = 1024,           // capacity in bytes
    parameter INIT_FILE = ""          // optional: preload RAM contents (hex bytes)
) (
    input  wire        clk,
    input  wire        we,            // store enable
    input  wire [31:0] addr,          // byte address
    input  wire [31:0] wdata,         // data to store
    input  wire [2:0]  funct3,        // width/sign select (see header)
    output reg  [31:0] rdata,         // loaded data (sign/zero extended)
    // ---- page-table-walk read ports (combinational, word reads) ----
    // Used by the MMU to fetch PTEs from RAM during translation. Unused
    // (and harmless) when no MMU is attached.
    input  wire [31:0] walk_addr1,
    input  wire [31:0] walk_addr2,
    output wire [31:0] walk_data1,
    output wire [31:0] walk_data2
);
    localparam ABITS = $clog2(BYTES);

    reg [7:0] mem [0:BYTES-1];

    // word reads for the page walker
    wire [ABITS-1:0] w1 = walk_addr1[ABITS-1:0];
    wire [ABITS-1:0] w2 = walk_addr2[ABITS-1:0];
    assign walk_data1 = {mem[w1+3], mem[w1+2], mem[w1+1], mem[w1]};
    assign walk_data2 = {mem[w2+3], mem[w2+2], mem[w2+1], mem[w2]};

    integer i;
    initial begin
        for (i = 0; i < BYTES; i = i + 1) mem[i] = 8'd0;
        // Preload initialized data (.rodata/.data) so string and array
        // constants are actually present in RAM. The file is byte-wide
        // hex with @address records (see Step 12).
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    wire [ABITS-1:0] a = addr[ABITS-1:0];

    // The four bytes at the access address, little-endian.
    wire [7:0]  b0 = mem[a];
    wire [7:0]  b1 = mem[a+1];
    wire [7:0]  b2 = mem[a+2];
    wire [7:0]  b3 = mem[a+3];
    wire [15:0] half = {b1, b0};
    wire [31:0] word = {b3, b2, b1, b0};

    // ---- Combinational read with sign / zero extension --------------
    always @(*) begin
        case (funct3)
            3'b000 : rdata = {{24{b0[7]}},  b0};    // LB  (sign-extend)
            3'b001 : rdata = {{16{half[15]}}, half}; // LH  (sign-extend)
            3'b010 : rdata = word;                  // LW
            3'b100 : rdata = {24'd0, b0};           // LBU (zero-extend)
            3'b101 : rdata = {16'd0, half};         // LHU (zero-extend)
            default: rdata = word;
        endcase
    end

    // ---- Clocked write: 1, 2, or 4 bytes ----------------------------
    always @(posedge clk) begin
        if (we) begin
            case (funct3)
                3'b000 : begin                       // SB
                    mem[a] <= wdata[7:0];
                end
                3'b001 : begin                       // SH
                    mem[a]   <= wdata[7:0];
                    mem[a+1] <= wdata[15:8];
                end
                3'b010 : begin                       // SW
                    mem[a]   <= wdata[7:0];
                    mem[a+1] <= wdata[15:8];
                    mem[a+2] <= wdata[23:16];
                    mem[a+3] <= wdata[31:24];
                end
                default : ; // other funct3 are not stores; do nothing
            endcase
        end
    end

endmodule

`default_nettype wire
