// =====================================================================
// s6_regfile.v  -  32 x 32-bit register file (distributed RAM)
// ---------------------------------------------------------------------
// Two asynchronous read ports, one synchronous write port. The reads are
// asynchronous on purpose: it is what lets the multi-cycle core decode,
// read, execute and write back inside a single EXEC cycle. On Spartan-6
// XST maps this to RAM32M / RAM32X1D distributed RAM (LUT RAM) -- about
// 64 LUTs -- instead of burning a whole 18 Kb block RAM on 128 bytes.
//
// x0 is not stored: reads of x0 return zero and writes to x0 are dropped.
// =====================================================================
`default_nettype none

module s6_regfile (
    input  wire        clk,
    input  wire        we,
    input  wire [4:0]  rs1_addr,
    input  wire [4:0]  rs2_addr,
    input  wire [4:0]  rd_addr,
    input  wire [31:0] rd_data,
    output wire [31:0] rs1_data,
    output wire [31:0] rs2_data
);
    reg [31:0] regs [0:31];

`ifdef S6_INIT_REGS
    integer i;
    initial for (i = 0; i < 32; i = i + 1) regs[i] = 32'h0;
`endif

    always @(posedge clk)
        if (we && rd_addr != 5'd0) regs[rd_addr] <= rd_data;

    assign rs1_data = (rs1_addr == 5'd0) ? 32'h0 : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'h0 : regs[rs2_addr];
endmodule

`default_nettype wire
