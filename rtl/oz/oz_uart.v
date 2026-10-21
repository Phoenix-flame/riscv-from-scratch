// =====================================================================
// oz_uart.v  -  valid/ready front for uart_tx (the standalone console)
// ---------------------------------------------------------------------
// The SoC's console device hands out bytes as a valid/ready stream. In a
// standalone build that stream goes to this serializer and out of a PL
// pin; in a PS-attached build it goes into an async FIFO instead
// (oz_host). `ready` drops the cycle a byte is taken and stays low until
// uart_tx has shifted out its stop bit.
// =====================================================================
`default_nettype none

module oz_uart #(
    parameter CLKS_PER_BIT = 434          // 50 MHz / 115200
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       valid,
    input  wire [7:0] data,
    output wire       ready,
    output wire       tx
);
    wire busy;
    reg  started;                         // covers the cycle before busy rises
    always @(posedge clk) started <= ~rst & valid & ready;
    assign ready = ~busy & ~started;

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .rst(rst), .data(data), .start(valid & ready), .tx(tx), .busy(busy)
    );
endmodule

`default_nettype wire
