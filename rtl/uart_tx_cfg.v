// =====================================================================
// uart_tx_cfg.v  -  Configurable UART transmitter (synthesizable)
// ---------------------------------------------------------------------
// Same framing config as uart_rx (clks_per_bit / data_bits / parity / stop2).
// Assert `send` for one cycle with `data`; `busy` is high until the frame
// (start + data + optional parity + 1/2 stop) is on the wire.
// =====================================================================
`default_nettype none

module uart_tx_cfg (
    input  wire        clk,
    input  wire        rst,
    input  wire        send,
    input  wire [7:0]  data,
    input  wire [15:0] clks_per_bit,
    input  wire [3:0]  data_bits,
    input  wire [1:0]  parity_mode,
    input  wire        stop2,
    output reg         tx,
    output reg         busy
);
    localparam S_IDLE=3'd0, S_START=3'd1, S_DATA=3'd2,
               S_PAR=3'd3,  S_STOP=3'd4;
    reg [2:0]  state;
    reg [15:0] cnt;
    reg [3:0]  bidx;
    reg [7:0]  sh;
    reg        par;
    reg        stopcnt;

    always @(posedge clk) begin
        if (rst) begin
            state<=S_IDLE; tx<=1'b1; busy<=1'b0; cnt<=0; bidx<=0; sh<=0;
            par<=0; stopcnt<=0;
        end else begin
            case (state)
                S_IDLE: begin
                    tx<=1'b1; busy<=1'b0;
                    if (send) begin
                        sh<=data; par<=1'b0; cnt<=0; bidx<=0; busy<=1'b1;
                        tx<=1'b0;                    // start bit
                        state<=S_START;
                    end
                end
                S_START: begin
                    if (cnt==clks_per_bit-1) begin cnt<=0; tx<=sh[0]; par<=sh[0];
                        bidx<=0; state<=S_DATA; end
                    else cnt<=cnt+1'b1;
                end
                S_DATA: begin
                    if (cnt==clks_per_bit-1) begin
                        cnt<=0;
                        if (bidx==data_bits-1) begin
                            if (parity_mode!=2'd0) begin
                                tx <= (parity_mode==2'd2) ? par : ~par;  // even/odd
                                state<=S_PAR;
                            end else begin tx<=1'b1; stopcnt<=0; state<=S_STOP; end
                        end else begin
                            bidx<=bidx+1'b1; tx<=sh[bidx+1]; par<=par^sh[bidx+1];
                        end
                    end else cnt<=cnt+1'b1;
                end
                S_PAR: begin
                    if (cnt==clks_per_bit-1) begin cnt<=0; tx<=1'b1; stopcnt<=0;
                        state<=S_STOP; end
                    else cnt<=cnt+1'b1;
                end
                S_STOP: begin
                    if (cnt==clks_per_bit-1) begin
                        cnt<=0;
                        if (stop2 && !stopcnt) stopcnt<=1'b1;   // second stop bit
                        else begin busy<=1'b0; state<=S_IDLE; end
                    end else cnt<=cnt+1'b1;
                end
                default: state<=S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
