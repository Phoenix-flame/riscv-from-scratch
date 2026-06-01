// =====================================================================
// timer.v  -  Memory-mapped cycle timer
// ---------------------------------------------------------------------
// Register map (offsets from the device base address):
//   +0x0  MTIME    : read  -> free-running cycle counter (increments /clk)
//   +0x4  MTIMECMP : r/w   -> compare value
//   +0x8  EXPIRED  : read  -> bit0 = (MTIME >= MTIMECMP)
//
// This is a polled timer: software reads MTIME, or sets MTIMECMP and
// spins reading EXPIRED. Turning "expired" into a real interrupt would
// need CSRs and trap handling (mstatus/mtvec/mcause), which this core
// doesn't implement -- a good advanced extension.
// =====================================================================
`default_nettype none

module timer (
    input  wire        clk,
    input  wire        rst,
    input  wire        sel,
    input  wire        we,
    input  wire [7:0]  addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    output wire        irq          // level: MTIME >= MTIMECMP
);
    reg [31:0] mtime;
    reg [31:0] mtimecmp;

    assign irq = (mtime >= mtimecmp);

    always @(posedge clk) begin
        if (rst) begin
            mtime    <= 32'd0;
            mtimecmp <= 32'hFFFF_FFFF;
        end else begin
            mtime <= mtime + 32'd1;                  // tick every cycle
            if (sel && we && (addr[3:0] == 4'h4))
                mtimecmp <= wdata;
        end
    end

    always @(*) begin
        case (addr[3:0])
            4'h0   : rdata = mtime;
            4'h4   : rdata = mtimecmp;
            4'h8   : rdata = (mtime >= mtimecmp) ? 32'd1 : 32'd0;
            default: rdata = 32'd0;
        endcase
    end
endmodule

`default_nettype wire
