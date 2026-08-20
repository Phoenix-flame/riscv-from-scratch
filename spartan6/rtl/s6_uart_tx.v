// =====================================================================
// s6_uart_tx.v  -  UART transmitter (5-8 data bits, parity, 1-2 stop)
// ---------------------------------------------------------------------
// Runs off the shared 16x-oversample tick from s6_uart, so TX and RX are
// guaranteed to agree on the bit rate: sixteen ticks make one bit.
//
// parity: [1] enable, [0] odd. So 00/01 = none, 10 = even, 11 = odd.
// The parity bit is computed in one XOR tree when the byte is loaded,
// not accumulated during the shift -- fewer states, same LUTs.
// =====================================================================
`default_nettype none

module s6_uart_tx (
    input  wire       clk,
    input  wire       rst,
    input  wire       os_tick,        // 16 per bit time
    input  wire       send,           // 1-cycle pulse, ignored while busy
    input  wire [7:0] data,
    input  wire [3:0] data_bits,      // 5..8
    input  wire [1:0] parity,
    input  wire       stop2,
    output reg        tx,
    output wire       busy
);
    localparam T_IDLE = 3'd0, T_START = 3'd1, T_DATA = 3'd2,
               T_PAR  = 3'd3, T_STOP  = 3'd4;

    reg [2:0] st;
    reg [3:0] tcnt;                   // oversample tick within the bit
    reg [2:0] bidx;
    reg [7:0] sh;
    reg       par_r, stop_second;

    wire [7:0] mask   = 8'hFF >> (4'd8 - data_bits);
    wire [2:0] lastb  = data_bits[2:0] - 3'd1;
    wire       tickend = os_tick & (tcnt == 4'd15);

    assign busy = (st != T_IDLE);

    always @(posedge clk) begin
        if (rst) begin
            st <= T_IDLE; tx <= 1'b1; tcnt <= 4'd0; bidx <= 3'd0;
            sh <= 8'd0; par_r <= 1'b0; stop_second <= 1'b0;
        end else begin
            if (os_tick) tcnt <= tickend ? 4'd0 : (tcnt + 4'd1);

            case (st)
                T_IDLE: if (send) begin
                    sh    <= data;
                    par_r <= parity[0] ^ (^(data & mask));
                    tx    <= 1'b0;                       // start bit
                    tcnt  <= 4'd0;
                    st    <= T_START;
                end

                T_START: if (tickend) begin
                    tx   <= sh[0];
                    bidx <= 3'd0;
                    st   <= T_DATA;
                end

                T_DATA: if (tickend) begin
                    if (bidx == lastb) begin
                        if (parity[1]) begin tx <= par_r;  st <= T_PAR; end
                        else begin
                            tx <= 1'b1; stop_second <= stop2; st <= T_STOP;
                        end
                    end else begin
                        sh   <= {1'b0, sh[7:1]};
                        tx   <= sh[1];
                        bidx <= bidx + 3'd1;
                    end
                end

                T_PAR: if (tickend) begin
                    tx <= 1'b1; stop_second <= stop2; st <= T_STOP;
                end

                T_STOP: if (tickend) begin
                    if (stop_second) stop_second <= 1'b0;
                    else             st <= T_IDLE;
                end

                default: st <= T_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
