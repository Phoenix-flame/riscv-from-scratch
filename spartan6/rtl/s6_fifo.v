// =====================================================================
// s6_fifo.v  -  Small synchronous FIFO (distributed RAM, FWFT)
// ---------------------------------------------------------------------
// First-word-fall-through: `rdata` is the head of the queue right now,
// no read latency, so the UART register file can return a byte in the
// same cycle the CPU reads RXTX. The storage is an asynchronous-read
// array, which on Spartan-6 becomes SRL16E/RAM32M distributed RAM -- a
// 16-deep by 8-bit FIFO costs about 8 LUTs plus the pointers.
//
// DEPTH must be a power of two. The pointers carry one extra bit so
// full and empty are told apart without a separate counter.
// =====================================================================
`default_nettype none

module s6_fifo #(
    parameter WIDTH = 8,
    parameter DEPTH = 16,
    // AW = log2(DEPTH), derived from it -- never override at instantiation.
    // ISE's XST rejects $clog2 in declarations, so the ladder below does
    // the same job as a constant expression every Verilog-2001 tool takes.
    parameter AW    = (DEPTH<=2)   ? 1 : (DEPTH<=4)   ? 2 : (DEPTH<=8)   ? 3 :
                      (DEPTH<=16)  ? 4 : (DEPTH<=32)  ? 5 : (DEPTH<=64)  ? 6 :
                      (DEPTH<=128) ? 7 : (DEPTH<=256) ? 8 : 9
) (
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    clr,        // synchronous flush
    input  wire                    wr,
    input  wire [WIDTH-1:0]        wdata,
    input  wire                    rd,
    output wire [WIDTH-1:0]        rdata,
    output wire                    full,
    output wire                    empty,
    output wire [AW:0]             level
);
    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [AW:0]      wptr, rptr;

    wire do_wr = wr & ~full;
    wire do_rd = rd & ~empty;

    always @(posedge clk) begin
        if (rst || clr) begin
            wptr <= 0;
            rptr <= 0;
        end else begin
            if (do_wr) wptr <= wptr + 1'b1;
            if (do_rd) rptr <= rptr + 1'b1;
        end
    end

    always @(posedge clk)
        if (do_wr) mem[wptr[AW-1:0]] <= wdata;

    assign rdata = mem[rptr[AW-1:0]];
    assign empty = (wptr == rptr);
    assign full  = (wptr[AW-1:0] == rptr[AW-1:0]) && (wptr[AW] != rptr[AW]);
    assign level = wptr - rptr;
endmodule

`default_nettype wire
