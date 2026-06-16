// =====================================================================
// fregfile.v  -  Floating-point register file (F extension, 32x 32-bit)
// ---------------------------------------------------------------------
// A second register file, separate from the integer one. f0 is NOT special
// here -- unlike x0, the floating-point f0 is an ordinary readable/writable
// register (the FP ISA has no hardwired-zero register; you make zero with
// fmv.w.x from x0 or fcvt.s.w). Two combinational read ports feed the FPU and
// the FP store path; one synchronous write port takes FPU / flw results.
//
// For single precision each register holds the 32-bit value directly. (The D
// extension would widen these to 64 bits and NaN-box single values in the
// upper half; see the step doc.)
// =====================================================================
`default_nettype none

module fregfile (
    input  wire        clk,
    input  wire        we,
    input  wire [4:0]  rs1_addr,
    input  wire [4:0]  rs2_addr,
    input  wire [4:0]  rd_addr,
    input  wire [31:0] rd_data,
    output wire [31:0] rs1_data,
    output wire [31:0] rs2_data
);
    reg [31:0] f [0:31];
    integer i;
    initial for (i = 0; i < 32; i = i + 1) f[i] = 32'd0;

    assign rs1_data = f[rs1_addr];
    assign rs2_data = f[rs2_addr];

    always @(posedge clk)
        if (we) f[rd_addr] <= rd_data;       // every f-reg is writable, incl. f0
endmodule

`default_nettype wire
