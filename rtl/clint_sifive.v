// =====================================================================
// clint_sifive.v  -  the standard RISC-V core-local interruptor (CLINT)
// ---------------------------------------------------------------------
// Step 27's clint.v packed mtime and mtimecmp into 16 bytes. The layout
// every RISC-V firmware expects -- the SiFive CLINT, DT compatible
// "sifive,clint0" / "riscv,clint0", which OpenSBI and QEMU's virt board
// use -- spreads the same registers over 64 KiB so that one block can
// serve up to 4095 harts:
//
//   +0x0000  msip[hart]      bit 0: machine software interrupt (IPI)
//   +0x4000  mtimecmp[hart]  64-bit, two 32-bit halves
//   +0xBFF8  mtime           64-bit, increments every clock, writable
//
// One hart here. mtime also leaves the block as a bus, because the core
// reads it as the `time` CSR (Zicntr) -- that is what lets S-mode code
// (and Linux) read the time without trapping to M.
// =====================================================================
`default_nettype none

module clint_sifive (
    input  wire        clk,
    input  wire        rst,
    input  wire        sel,
    input  wire        we,
    input  wire [15:0] addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    output wire        timer_irq,       // MTIP: mtime >= mtimecmp
    output wire        soft_irq,        // MSIP
    output wire [63:0] mtime_o
);
    reg [63:0] mtime, mtimecmp;
    reg        msip;

    assign timer_irq = (mtime >= mtimecmp);
    assign soft_irq  = msip;
    assign mtime_o   = mtime;

    always @(posedge clk) begin
        if (rst) begin
            mtime    <= 64'd0;
            mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;   // no interrupt until armed
            msip     <= 1'b0;
        end else begin
            mtime <= mtime + 64'd1;
            if (sel && we) case (addr)
                16'h0000: msip            <= wdata[0];
                16'h4000: mtimecmp[31:0]  <= wdata;
                16'h4004: mtimecmp[63:32] <= wdata;
                16'hBFF8: mtime[31:0]     <= wdata;     // a write wins over the tick
                16'hBFFC: mtime[63:32]    <= wdata;
                default: ;
            endcase
        end
    end

    always @(*) begin
        case (addr)
            16'h0000: rdata = {31'd0, msip};
            16'h4000: rdata = mtimecmp[31:0];
            16'h4004: rdata = mtimecmp[63:32];
            16'hBFF8: rdata = mtime[31:0];
            16'hBFFC: rdata = mtime[63:32];
            default:  rdata = 32'd0;
        endcase
    end
endmodule

`default_nettype wire
