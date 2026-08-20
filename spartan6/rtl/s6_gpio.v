// =====================================================================
// s6_gpio.v  -  Output / input port with change interrupts
// ---------------------------------------------------------------------
//   0x00 OUT      RW  the driven value
//   0x04 IN       R   the synchronised input value
//   0x08 IE       RW  per-pin change-interrupt enable
//   0x0C IP       R   per-pin change detected  (W1C)
//   0x10 OUT_SET  W   set   the bits written as 1
//   0x14 OUT_CLR  W   clear the bits written as 1
//   0x18 OUT_TGL  W   toggle the bits written as 1
//
// The set/clear/toggle aliases exist so an interrupt handler can drive a
// pin without the read-modify-write race that OUT alone would need.
//
// Inputs go through a two-flop synchroniser before the edge detector, so
// a bouncing switch produces interrupts but never metastability.
// =====================================================================
`default_nettype none

module s6_gpio #(
    parameter WIDTH = 8
) (
    input  wire             clk,
    input  wire             rst,
    input  wire             sel,
    input  wire             re,
    input  wire [3:0]       be,
    input  wire [7:0]       addr,
    input  wire [31:0]      wdata,
    output reg  [31:0]      rdata,
    output wire             ready,
    output wire [WIDTH-1:0] gpio_out,
    input  wire [WIDTH-1:0] gpio_in,
    output wire             irq
);
    reg [WIDTH-1:0] out_r, ie_r, ip_r;
    reg [WIDTH-1:0] sync0, sync1, prev;

    wire wr = sel & (|be);
    wire rd = sel & re;
    reg  rd_ack;
    always @(posedge clk) rd_ack <= rst ? 1'b0 : (rd & ~rd_ack);
    assign ready = wr | rd_ack;

    always @(posedge clk) begin
        if (rst) begin
            sync0 <= {WIDTH{1'b0}}; sync1 <= {WIDTH{1'b0}}; prev <= {WIDTH{1'b0}};
        end else begin
            sync0 <= gpio_in;
            sync1 <= sync0;
            prev  <= sync1;
        end
    end
    wire [WIDTH-1:0] changed = sync1 ^ prev;

    always @(posedge clk) begin
        if (rst) begin
            out_r <= {WIDTH{1'b0}};
            ie_r  <= {WIDTH{1'b0}};
            ip_r  <= {WIDTH{1'b0}};
        end else begin
            if (wr) case (addr[7:0])
                8'h00: out_r <= wdata[WIDTH-1:0];
                8'h08: ie_r  <= wdata[WIDTH-1:0];              // 0x0C (W1C) below
                8'h10: out_r <= out_r |  wdata[WIDTH-1:0];
                8'h14: out_r <= out_r & ~wdata[WIDTH-1:0];
                8'h18: out_r <= out_r ^  wdata[WIDTH-1:0];
                default: ;
            endcase
            // a change latches even in the cycle software clears the bit
            ip_r <= (wr && addr[7:0] == 8'h0C)
                    ? ((ip_r & ~wdata[WIDTH-1:0]) | changed)
                    : (ip_r | changed);
        end
    end

    always @(posedge clk) begin
        if (rd & ~rd_ack) case (addr[7:0])
            8'h00:   rdata <= {{(32-WIDTH){1'b0}}, out_r};
            8'h04:   rdata <= {{(32-WIDTH){1'b0}}, sync1};
            8'h08:   rdata <= {{(32-WIDTH){1'b0}}, ie_r};
            8'h0C:   rdata <= {{(32-WIDTH){1'b0}}, ip_r};
            default: rdata <= 32'd0;
        endcase
    end

    assign gpio_out = out_r;
    assign irq      = |(ip_r & ie_r);
endmodule

`default_nettype wire
