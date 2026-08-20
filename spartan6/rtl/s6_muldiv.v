// =====================================================================
// s6_muldiv.v  -  Sequential RV32M multiply / divide unit
// ---------------------------------------------------------------------
// One 33-bit add/sub, one 65-bit shift register, 32 iterations. That is
// the whole unit: ~150 LUTs/FFs, which is what "M without a DSP" costs.
//
//   MUL / MULH / MULHSU / MULHU   shift-and-add, 34 cycles
//   DIV / DIVU / REM / REMU       restoring division, 34 cycles
//
// Signed multiply without a separate negate stage: sign-extend the
// multiplicand into the 33-bit accumulator, and on the LAST iteration
// *subtract* instead of add when the multiplier is signed and negative.
// That is the textbook two's-complement shift-add multiplier, and it
// covers MULHSU for free (sign-extend a, do not negate on the last step).
//
// Division is restoring: shift the dividend into the remainder one bit at
// a time, trial-subtract the divisor, keep the subtraction if it did not
// borrow. Signed forms divide the magnitudes and fix the signs at the end
// (the RISC-V rule: the remainder takes the sign of the dividend).
//
// Set MUL_DSP=1 to compute the products in one cycle with a 33x33 signed
// multiply instead; XST maps that onto four DSP48A1 slices (the LX9 has
// 16). Division stays sequential either way -- there is no divider in a
// DSP48A1.
//
// Handshake: pulse `start` for one cycle with `op`/`a`/`b` valid. `busy`
// goes high immediately and `done` pulses for one cycle with `result`.
// =====================================================================
`default_nettype none

module s6_muldiv #(
    parameter MUL_DSP = 0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [2:0]  op,          // funct3 of the OP-with-funct7=1 instruction
    input  wire [31:0] a,           // rs1
    input  wire [31:0] b,           // rs2
    output wire        busy,
    output wire        done,
    output reg  [31:0] result
);
    // funct3 map: 000 MUL 001 MULH 010 MULHSU 011 MULHU
    //             100 DIV 101 DIVU 110 REM    111 REMU
    localparam ST_IDLE = 2'd0, ST_RUN = 2'd1, ST_FIX = 2'd2;

    reg  [1:0]  state;
    reg  [5:0]  count;
    reg  [32:0] acc;                // remainder / product high (+1 guard bit)
    reg  [31:0] q;                  // multiplier / quotient / product low
    reg  [32:0] m;                  // multiplicand / divisor
    reg  [2:0]  op_q;
    reg         msign_q;            // multiplier is signed  (MULH only)
    reg         qneg_q, rneg_q;     // division sign fixups
    reg         shortcut;           // divide-by-zero / overflow: skip the loop

    wire is_div = op_q[2];
    assign busy = (state != ST_IDLE) | start;
    assign done = (state == ST_FIX);      // result is valid in this cycle

    // ---- decode the incoming operation (combinational, at `start`) ----
    wire       in_div    = op[2];
    wire       a_signed  = ~op[2] & (op[1:0] == 2'b01 || op[1:0] == 2'b10)  // MULH, MULHSU
                         |  op[2] & ~op[0];                                 // DIV, REM
    wire       b_signed  = ~op[2] & (op[1:0] == 2'b01)                      // MULH only
                         |  op[2] & ~op[0];                                 // DIV, REM
    wire       neg_a     = a_signed & a[31];
    wire       neg_b     = b_signed & b[31];
    wire [31:0] mag_a    = neg_a ? (~a + 32'd1) : a;
    wire [31:0] mag_b    = neg_b ? (~b + 32'd1) : b;

    wire       div_zero  = in_div & (b == 32'd0);
    wire       div_ovf   = in_div & ~op[0] & (a == 32'h8000_0000) & (b == 32'hFFFF_FFFF);

    // ---- optional single-cycle multiplier (DSP48A1) --------------------
    wire [63:0] fast_prod;
    generate
        if (MUL_DSP) begin : g_dsp
            wire signed [32:0] sa = {a_signed & a[31], a};
            wire signed [32:0] sb = {b_signed & b[31], b};
            wire signed [65:0] p  = sa * sb;
            assign fast_prod = p[63:0];
        end else begin : g_no_dsp
            assign fast_prod = 64'd0;
        end
    endgenerate

    // ---- the shared 33-bit add/sub -------------------------------------
    // The accumulate/shift is done 34 bits wide: sign-extending both the
    // accumulator and the multiplicand by one bit is what lets a SIGNED
    // right shift also be correct for the unsigned forms. Doing the add in
    // 33 bits and replicating bit 32 looks equivalent and is not -- an
    // unsigned partial product that carries into bit 32 then gets a run of
    // ones shifted in behind it, and MULHU comes out wrong.
    wire        last    = (count == 6'd31);
    wire        mul_sub = last & msign_q & q[0];                 // signed last step
    wire [33:0] acc34   = {acc[32], acc};
    wire [33:0] m34     = {m[32], m};
    wire [33:0] mul_sum = q[0] ? (mul_sub ? acc34 - m34 : acc34 + m34) : acc34;

    wire [32:0] rem_sh  = {acc[31:0], q[31]};                    // shift dividend in
    wire [32:0] rem_dif = rem_sh - m;
    wire        rem_fit = ~rem_dif[32];                          // no borrow -> keep it

    always @(posedge clk) begin
        if (rst) begin
            state <= ST_IDLE; count <= 6'd0;
            acc <= 33'd0; q <= 32'd0; m <= 33'd0; op_q <= 3'd0;
            msign_q <= 1'b0; qneg_q <= 1'b0; rneg_q <= 1'b0; shortcut <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: if (start) begin
                    op_q     <= op;
                    msign_q  <= b_signed;
                    qneg_q   <= neg_a ^ neg_b;
                    rneg_q   <= neg_a;
                    count    <= 6'd0;
                    shortcut <= div_zero | div_ovf;
                    if (in_div) begin
                        acc <= 33'd0;
                        q   <= mag_a;
                        m   <= {1'b0, mag_b};
                        if (div_zero) begin
                            // DIV/DIVU -> all ones, REM/REMU -> the dividend
                            q <= 32'hFFFF_FFFF; acc <= {1'b0, a};
                            state <= ST_FIX;
                        end else if (div_ovf) begin
                            q <= 32'h8000_0000; acc <= 33'd0;    // quotient -2^31, rem 0
                            state <= ST_FIX;
                        end else
                            state <= ST_RUN;
                    end else if (MUL_DSP) begin
                        acc   <= {1'b0, fast_prod[63:32]};
                        q     <= fast_prod[31:0];
                        state <= ST_FIX;
                    end else begin
                        acc   <= 33'd0;
                        q     <= b;
                        m     <= {a_signed & a[31], a};
                        state <= ST_RUN;
                    end
                end

                ST_RUN: begin
                    if (is_div) begin
                        acc <= rem_fit ? rem_dif : rem_sh;
                        q   <= {q[30:0], rem_fit};
                    end else begin
                        acc <= mul_sum[33:1];                    // arithmetic >>1
                        q   <= {mul_sum[0], q[31:1]};
                    end
                    count <= count + 6'd1;
                    if (last) state <= ST_FIX;
                end

                ST_FIX: state <= ST_IDLE;   // `done` is high here; result valid

                default: state <= ST_IDLE;
            endcase
        end
    end

    // ---- result select (valid in ST_FIX, i.e. the `done` cycle) --------
    wire [31:0] quo_fixed = (qneg_q & ~shortcut) ? (~q + 32'd1) : q;
    wire [31:0] rem_fixed = (rneg_q & ~shortcut) ? (~acc[31:0] + 32'd1) : acc[31:0];

    always @(*) begin
        if (op_q[2])                      // division family
            result = op_q[1] ? rem_fixed : quo_fixed;
        else                              // multiplication family
            result = (op_q[1:0] == 2'b00) ? q : acc[31:0];
    end
endmodule

`default_nettype wire
