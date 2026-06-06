// =====================================================================
// uart_rx.v  -  Configurable UART receiver with idle-line detection
// ---------------------------------------------------------------------
// Runtime-configurable framing (clks_per_bit / data_bits / parity / stop2).
// Samples each bit at its midpoint; emits `valid` for one cycle with the
// byte and framing/parity error flags.
//
// IDLE-LINE DETECTION (for "receive to idle"): after at least one byte has
// arrived, if the line then stays idle (high, no new start bit) for
// `idle_bits` bit-periods, `idle` pulses for one cycle. This marks the end
// of a variable-length message without knowing its length in advance.
// =====================================================================
`default_nettype none

module uart_rx (
    input  wire        clk,
    input  wire        rst,
    input  wire        rx,                 // serial in (async)
    input  wire [15:0] clks_per_bit,
    input  wire [3:0]  data_bits,          // 5..8
    input  wire [1:0]  parity_mode,        // 0 none / 1 odd / 2 even
    input  wire        stop2,
    input  wire [4:0]  idle_bits,          // idle bit-times before `idle` (0 disables)
    output reg  [7:0]  data,
    output reg         valid,
    output reg         frame_err,
    output reg         parity_err,
    output reg         idle
);
    localparam S_IDLE=3'd0, S_START=3'd1, S_DATA=3'd2, S_PAR=3'd3, S_STOP=3'd4;
    reg [2:0]  state;
    reg [15:0] cnt;
    reg [3:0]  bidx;
    reg [7:0]  sh;
    reg        par, stopcnt;
    reg [1:0]  rxq;
    wire       rxs = rxq[1];

    // idle-line detector
    reg [15:0] idle_clk;
    reg [4:0]  idle_bit;
    reg        rx_active;                   // a byte arrived since the last idle

    always @(posedge clk) begin
        if (rst) begin
            state<=S_IDLE; valid<=0; frame_err<=0; parity_err<=0; idle<=0;
            rxq<=2'b11; cnt<=0; bidx<=0; sh<=0; par<=0; stopcnt<=0; data<=0;
            idle_clk<=0; idle_bit<=0; rx_active<=0;
        end else begin
            rxq   <= {rxq[0], rx};
            valid <= 1'b0;
            idle  <= 1'b0;
            case (state)
                S_IDLE: if (~rxs) begin cnt<=0; state<=S_START; end
                S_START: begin
                    if (cnt == {1'b0, clks_per_bit[15:1]}) begin
                        if (~rxs) begin cnt<=0; bidx<=0; sh<=0; par<=0;
                            frame_err<=0; parity_err<=0; state<=S_DATA; end
                        else state<=S_IDLE;
                    end else cnt<=cnt+1'b1;
                end
                S_DATA: begin
                    if (cnt == clks_per_bit-1) begin
                        cnt<=0; sh[bidx]<=rxs; par<=par^rxs;
                        if (bidx == data_bits-1)
                            state <= (parity_mode!=2'd0) ? S_PAR : S_STOP;
                        else bidx<=bidx+1'b1;
                    end else cnt<=cnt+1'b1;
                end
                S_PAR: begin
                    if (cnt == clks_per_bit-1) begin
                        cnt<=0; stopcnt<=1'b0;
                        if (parity_mode==2'd2) parity_err <= (rxs != par);
                        else                   parity_err <= (rxs != ~par);
                        state<=S_STOP;
                    end else cnt<=cnt+1'b1;
                end
                S_STOP: begin
                    if (cnt == clks_per_bit-1) begin
                        cnt<=0;
                        if (~rxs) frame_err<=1'b1;
                        if (stop2 && !stopcnt) stopcnt<=1'b1;
                        else begin
                            data<=sh; valid<=1'b1; rx_active<=1'b1; state<=S_IDLE;
                        end
                    end else cnt<=cnt+1'b1;
                end
                default: state<=S_IDLE;
            endcase

            // ---- idle-line detection (runs while we're between frames) ----
            if (state == S_IDLE) begin
                if (~rxs) begin idle_clk<=0; idle_bit<=0; end     // a new start is coming
                else if (idle_clk == clks_per_bit-1) begin
                    idle_clk <= 0;
                    if ((idle_bits != 5'd0) && (idle_bit >= idle_bits-1)) begin
                        if (rx_active) begin idle<=1'b1; rx_active<=1'b0; end
                    end else idle_bit <= idle_bit + 1'b1;
                end else idle_clk <= idle_clk + 1'b1;
            end else begin
                idle_clk <= 0; idle_bit <= 0;                     // receiving -> reset
            end
        end
    end
endmodule

`default_nettype wire
