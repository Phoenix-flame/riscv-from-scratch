// =====================================================================
// s6_clint.v  -  Core-local interruptor: mtime, mtimecmp, msip
// ---------------------------------------------------------------------
// The standard RISC-V CLINT register layout, so firmware written for any
// other RISC-V machine finds its timer where it expects it:
//
//   +0x0000  MSIP      b0 = machine software interrupt pending
//   +0x4000  MTIMECMP  lo / +0x4004 hi
//   +0xBFF8  MTIME     lo / +0xBFFC hi
//
// mtime is a real-time counter, not a cycle counter: TICK_DIV divides the
// system clock down so one tick is one microsecond regardless of what the
// PLL is set to. That makes `rdtime` and mtimecmp deadlines portable
// across clock frequencies -- and the core exports the same counter as
// the `time` CSR.
//
// Writing MTIME lo/hi is allowed (a debugger or a test needs it); the
// 64-bit compare is unsigned and level-triggered, exactly as the spec
// requires: mtip stays high until software moves mtimecmp forward.
// =====================================================================
`default_nettype none

module s6_clint #(
    parameter TICK_DIV = 48            // clocks per mtime tick (1 us at 48 MHz)
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        sel,
    input  wire        re,
    input  wire [3:0]  be,
    input  wire [15:0] addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    output wire        ready,
    output wire [63:0] mtime,
    output wire        timer_irq,
    output wire        soft_irq
);
    reg [63:0] mtime_r, mtimecmp_r;
    reg [31:0] divcnt;
    reg        msip_r;

    wire wr = sel & (|be);
    wire rd = sel & re;
    reg  rd_ack;
    always @(posedge clk) rd_ack <= rst ? 1'b0 : (rd & ~rd_ack);
    assign ready = wr | rd_ack;

    wire tick = (TICK_DIV <= 1) ? 1'b1 : (divcnt == (TICK_DIV - 1));

    always @(posedge clk) begin
        if (rst) begin
            mtime_r <= 64'd0;
            mtimecmp_r <= 64'hFFFF_FFFF_FFFF_FFFF;   // never fire until armed
            divcnt <= 32'd0;
            msip_r <= 1'b0;
        end else begin
            divcnt <= tick ? 32'd0 : (divcnt + 32'd1);
            if (tick) mtime_r <= mtime_r + 64'd1;

            if (wr) case (addr)
                16'h0000: msip_r            <= wdata[0];
                16'h4000: mtimecmp_r[31:0]  <= wdata;
                16'h4004: mtimecmp_r[63:32] <= wdata;
                16'hBFF8: mtime_r[31:0]     <= wdata;
                16'hBFFC: mtime_r[63:32]    <= wdata;
                default: ;
            endcase
        end
    end

    always @(posedge clk) begin
        if (rd & ~rd_ack) case (addr)
            16'h0000: rdata <= {31'b0, msip_r};
            16'h4000: rdata <= mtimecmp_r[31:0];
            16'h4004: rdata <= mtimecmp_r[63:32];
            16'hBFF8: rdata <= mtime_r[31:0];
            16'hBFFC: rdata <= mtime_r[63:32];
            default:  rdata <= 32'd0;
        endcase
    end

    assign mtime     = mtime_r;
    assign timer_irq = (mtime_r >= mtimecmp_r);
    assign soft_irq  = msip_r;
endmodule

`default_nettype wire
