// =====================================================================
// regfile.v  -  32 x 32-bit register file for RV32I
// ---------------------------------------------------------------------
// Two asynchronous (combinational) read ports and one synchronous
// (clocked) write port.  Register x0 is hard-wired to zero: reads of
// it always return 0 and writes to it are discarded.
//
// Read ports are combinational on purpose: in a single-cycle CPU the
// datapath must read operands, compute, and write back all within one
// clock period, so reads cannot wait for an edge.  The write lands on
// the rising clock edge, at the end of the cycle.
// =====================================================================
`default_nettype none

module regfile (
    input  wire        clk,
    input  wire        we,        // write enable
    input  wire [4:0]  rs1_addr,  // read address 1
    input  wire [4:0]  rs2_addr,  // read address 2
    input  wire [4:0]  rd_addr,   // write address
    input  wire [31:0] rd_data,   // write data
    output wire [31:0] rs1_data,  // read data 1
    output wire [31:0] rs2_data   // read data 2
);

    // The storage: 32 registers, each 32 bits wide.
    reg [31:0] regs [0:31];

    integer i;
    // Simulation convenience: start every register at 0 so waveforms and
    // test programs are deterministic.  (Real hardware would use a reset
    // sequence or rely on software to initialize; RV32I leaves the GPRs
    // other than x0 undefined at reset.)
    initial begin
        for (i = 0; i < 32; i = i + 1) regs[i] = 32'd0;
    end

    // ---- Synchronous write -----------------------------------------
    // Writes happen on the rising edge, and never to x0.
    always @(posedge clk) begin
        if (we && (rd_addr != 5'd0))
            regs[rd_addr] <= rd_data;
    end

    // ---- Asynchronous reads ----------------------------------------
    // Reading x0 always yields 0, regardless of what's in regs[0].
    assign rs1_data = (rs1_addr == 5'd0) ? 32'd0 : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'd0 : regs[rs2_addr];

endmodule

`default_nettype wire
