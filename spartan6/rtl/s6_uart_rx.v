// =====================================================================
// s6_uart_rx.v  -  UART receiver, 16x oversampled, 3-sample majority
// ---------------------------------------------------------------------
// The receiver does not just sample once in the middle of each bit: it
// takes three samples at oversample ticks 6, 7 and 8 and takes the
// majority. That is what makes a UART tolerate a noisy or slightly
// slow-edged line instead of dropping a byte on a single glitch.
//
// The start bit is re-checked at its own midpoint, so a narrow spike on
// an idle line is rejected as a false start instead of shifting garbage
// into the byte.
//
// IDLE detection ("receive to idle"): after a byte has arrived, if the
// line then stays high for `idle_bits` bit-times, `idle` pulses once.
// That is how you delimit a variable-length message without a protocol.
// =====================================================================
`default_nettype none

module s6_uart_rx (
    input  wire       clk,
    input  wire       rst,
    input  wire       os_tick,        // 16 per bit time
    input  wire       rx,             // raw pin
    input  wire [3:0] data_bits,      // 5..8
    input  wire [1:0] parity,         // [1] enable, [0] odd
    input  wire [4:0] idle_bits,      // 0 disables the idle event
    output reg  [7:0] data,
    output reg        valid,          // 1-cycle pulse: `data` is new
    output reg        frame_err,
    output reg        parity_err,
    output reg        idle            // 1-cycle pulse
);
    localparam R_IDLE = 3'd0, R_START = 3'd1, R_DATA = 3'd2,
               R_PAR  = 3'd3, R_STOP  = 3'd4;

    // ---- two-stage synchroniser: the pin is asynchronous ----
    reg [1:0] sync;
    wire      rxs = sync[1];
    always @(posedge clk) sync <= rst ? 2'b11 : {sync[0], rx};

    reg [2:0] st;
    reg [3:0] tcnt;
    reg [2:0] bidx;
    reg [7:0] sh;
    reg [1:0] smpl;                   // 3-sample majority accumulator
    reg       par_acc;
    reg [8:0] idle_cnt;               // oversample ticks of quiet line
    reg       armed;                  // a byte arrived since the last idle

    wire [2:0] lastb   = data_bits[2:0] - 3'd1;
    wire       tickend = os_tick & (tcnt == 4'd15);
    wire       majority = smpl[1];    // 2 or 3 of the 3 samples were high
    wire [8:0] idle_lim = {idle_bits, 4'b0000};   // idle_bits * 16

    always @(posedge clk) begin
        if (rst) begin
            st <= R_IDLE; tcnt <= 4'd0; bidx <= 3'd0; sh <= 8'd0;
            smpl <= 2'd0; par_acc <= 1'b0; data <= 8'd0;
            valid <= 1'b0; frame_err <= 1'b0; parity_err <= 1'b0;
            idle <= 1'b0; idle_cnt <= 9'd0; armed <= 1'b0;
        end else begin
            valid <= 1'b0;
            idle  <= 1'b0;

            // ---- oversample tick housekeeping ----
            if (os_tick && st != R_IDLE)
                tcnt <= tickend ? 4'd0 : (tcnt + 4'd1);

            // ---- 3-sample majority window, common to every bit ----
            if (os_tick && st != R_IDLE) begin
                if      (tcnt == 4'd6)                 smpl <= {1'b0, rxs};
                else if (tcnt == 4'd7 || tcnt == 4'd8) smpl <= smpl + {1'b0, rxs};
            end

            // ---- quiet-line timer ----
            if (st != R_IDLE || !rxs) begin
                idle_cnt <= 9'd0;
            end else if (os_tick && idle_bits != 5'd0 && idle_cnt < idle_lim) begin
                idle_cnt <= idle_cnt + 9'd1;
                if (idle_cnt + 9'd1 == idle_lim && armed) begin
                    idle  <= 1'b1;
                    armed <= 1'b0;
                end
            end

            case (st)
                R_IDLE: if (!rxs) begin           // a falling edge: maybe a start bit
                    // The clock that detects the edge is itself part of the
                    // start bit. If an oversample tick lands on it, that tick
                    // is already spent, so the counter has to start at 1 --
                    // otherwise every frame is 17 tick-times long instead of
                    // 16 and the receiver walks one clock later per byte. At
                    // the minimum divisor (16 clocks/bit, one tick per clock)
                    // that is a whole bit slip after eight back-to-back
                    // bytes; at larger divisors it is a slow phase creep.
                    tcnt <= os_tick ? 4'd1 : 4'd0;
                    st   <= R_START;
                end

                R_START: if (os_tick) begin
                    if (tcnt == 4'd7 && rxs)      // midpoint is high -> noise
                        st <= R_IDLE;
                    else if (tcnt == 4'd15) begin
                        bidx       <= 3'd0;
                        sh         <= 8'd0;
                        par_acc    <= 1'b0;
                        parity_err <= 1'b0;
                        st         <= R_DATA;
                    end
                end

                R_DATA: if (tickend) begin
                    sh      <= {majority, sh[7:1]};
                    par_acc <= par_acc ^ majority;
                    if (bidx == lastb)
                        st <= parity[1] ? R_PAR : R_STOP;
                    else
                        bidx <= bidx + 3'd1;
                end

                R_PAR: if (tickend) begin
                    // odd parity => the total number of ones must be odd
                    parity_err <= (par_acc ^ majority) != parity[0];
                    st         <= R_STOP;
                end

                R_STOP: if (tickend) begin
                    // right-align when fewer than 8 data bits were sent
                    data      <= sh >> (4'd8 - data_bits);
                    frame_err <= ~majority;       // stop bit must be high
                    valid     <= 1'b1;
                    armed     <= 1'b1;
                    st        <= R_IDLE;
                end

                default: st <= R_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
