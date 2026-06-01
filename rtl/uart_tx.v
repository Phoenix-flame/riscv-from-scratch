// =====================================================================
// uart_tx.v  -  Synthesizable UART transmitter (real serializer)
// ---------------------------------------------------------------------
// Unlike the simulation model (uart.v, which uses $write), this drives a
// physical serial line: idle-high, one start bit (0), 8 data bits LSB
// first, one stop bit (1). One bit lasts CLKS_PER_BIT clock cycles, so
// the baud rate is  CLK_FREQ / CLKS_PER_BIT.
//
//   Example: 100 MHz clock, 115200 baud -> CLKS_PER_BIT = 868.
//
// This module is fully synthesizable (no $-system tasks).
// =====================================================================
`default_nettype none

module uart_tx #(
    parameter CLKS_PER_BIT = 868
) (
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] data,    // byte to send (latched on `start`)
    input  wire       start,   // pulse high for one cycle to begin
    output reg        tx,      // serial output line (idle high)
    output reg        busy     // high while a byte is in flight
);
    localparam S_IDLE = 2'd0, S_START = 2'd1, S_DATA = 2'd2, S_STOP = 2'd3;

    reg [1:0]  state;
    reg [15:0] clk_cnt;        // counts cycles within one bit
    reg [2:0]  bit_idx;        // which data bit (0..7)
    reg [7:0]  shreg;          // shift register holding the byte

    always @(posedge clk) begin
        if (rst) begin
            state   <= S_IDLE;
            tx      <= 1'b1;   // idle line is high
            busy    <= 1'b0;
            clk_cnt <= 16'd0;
            bit_idx <= 3'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    tx      <= 1'b1;
                    busy    <= 1'b0;
                    clk_cnt <= 16'd0;
                    bit_idx <= 3'd0;
                    if (start) begin
                        shreg <= data;
                        busy  <= 1'b1;
                        state <= S_START;
                    end
                end

                S_START: begin       // start bit = 0
                    tx <= 1'b0;
                    if (clk_cnt == CLKS_PER_BIT-1) begin
                        clk_cnt <= 16'd0;
                        state   <= S_DATA;
                    end else clk_cnt <= clk_cnt + 16'd1;
                end

                S_DATA: begin        // 8 data bits, LSB first
                    tx <= shreg[0];
                    if (clk_cnt == CLKS_PER_BIT-1) begin
                        clk_cnt <= 16'd0;
                        shreg   <= {1'b0, shreg[7:1]};   // shift right
                        if (bit_idx == 3'd7) begin
                            bit_idx <= 3'd0;
                            state   <= S_STOP;
                        end else bit_idx <= bit_idx + 3'd1;
                    end else clk_cnt <= clk_cnt + 16'd1;
                end

                S_STOP: begin        // stop bit = 1
                    tx <= 1'b1;
                    if (clk_cnt == CLKS_PER_BIT-1) begin
                        clk_cnt <= 16'd0;
                        busy    <= 1'b0;
                        state   <= S_IDLE;
                    end else clk_cnt <= clk_cnt + 16'd1;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
