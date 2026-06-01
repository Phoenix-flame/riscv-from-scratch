// =====================================================================
// uart_hw.v  -  Synthesizable memory-mapped UART (wraps uart_tx)
// ---------------------------------------------------------------------
// The hardware counterpart of the simulation model uart.v. Same register
// map, but a write actually serializes the byte out the `tx` pin, and
// STATUS reflects real busy/ready so software must poll before writing.
//   +0x0  TX     : write a byte -> transmit (ignored while busy)
//   +0x4  STATUS : read -> bit0 = TX ready (1 = idle, can accept a byte)
// =====================================================================
`default_nettype none

module uart_hw #(
    parameter CLKS_PER_BIT = 868
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        sel,
    input  wire        we,
    input  wire [7:0]  addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    output wire        tx          // physical serial line
);
    wire       busy;
    reg        start;
    reg  [7:0] tdata;

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .rst(rst), .data(tdata), .start(start),
        .tx(tx), .busy(busy)
    );

    // Issue a one-cycle start pulse on a write to TX, if not busy.
    always @(posedge clk) begin
        if (rst) start <= 1'b0;
        else begin
            start <= 1'b0;
            if (sel && we && (addr[3:0] == 4'h0) && !busy) begin
                tdata <= wdata[7:0];
                start <= 1'b1;
            end
        end
    end

    always @(*) begin
        case (addr[3:0])
            4'h4   : rdata = {31'b0, ~busy};   // STATUS: ready = !busy
            default: rdata = 32'd0;
        endcase
    end
endmodule

`default_nettype wire
