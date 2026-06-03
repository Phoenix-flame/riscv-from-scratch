// =====================================================================
// clint.v  -  64-bit CLINT-style machine timer (FreeRTOS-compatible)
// ---------------------------------------------------------------------
// The standard RISC-V machine timer is a 64-bit free-running counter
// (mtime) and a 64-bit compare (mtimecmp); the timer interrupt is the
// level mtime >= mtimecmp. RV32 accesses each as two 32-bit words, so
// the register map exposes low/high halves:
//
//   +0x0  MTIME    [31:0]   (read-only, increments every clock)
//   +0x4  MTIME    [63:32]
//   +0x8  MTIMECMP [31:0]   (read/write)
//   +0xC  MTIMECMP [63:32]
//
// FreeRTOS: configMTIME_BASE_ADDRESS = base, configMTIMECMP_BASE_ADDRESS
// = base + 8. Writing a future mtimecmp de-asserts the interrupt.
// =====================================================================
`default_nettype none

module clint (
    input  wire        clk,
    input  wire        rst,
    input  wire        sel,
    input  wire        we,
    input  wire [7:0]  addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    output wire        irq          // level: mtime >= mtimecmp
);
    reg [63:0] mtime;
    reg [63:0] mtimecmp;

    assign irq = (mtime >= mtimecmp);

    always @(posedge clk) begin
        if (rst) begin
            mtime    <= 64'd0;
            mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;   // no interrupt until armed
        end else begin
            mtime <= mtime + 64'd1;                 // free-running tick
            if (sel && we) begin
                if (addr[3:0] == 4'h8) mtimecmp[31:0]  <= wdata;
                if (addr[3:0] == 4'hC) mtimecmp[63:32] <= wdata;
            end
        end
    end

    always @(*) begin
        case (addr[3:0])
            4'h0:    rdata = mtime[31:0];
            4'h4:    rdata = mtime[63:32];
            4'h8:    rdata = mtimecmp[31:0];
            4'hC:    rdata = mtimecmp[63:32];
            default: rdata = 32'd0;
        endcase
    end
endmodule

`default_nettype wire
