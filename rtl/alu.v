// =====================================================================
// alu.v  -  ALU for RV32IM (base integer + multiply/divide)
// ---------------------------------------------------------------------
// Combinational. 5-bit alu_op selects the operation. The multiply and
// divide operations implement the RV32M extension, including its
// defined results for divide-by-zero and signed overflow.
//
// NOTE: multiply/divide are written combinationally (Verilog * / %) for
// clarity. On an FPGA the multiplier maps to DSP blocks; a combinational
// divider is large -- a real core uses a multi-cycle divider. Fine here
// for a teaching/simulation core.
//
// M_EXT=0 (the configurable core, Step 45) leaves the multiplier and the
// divider out entirely: the RV32M ops then read as 0, and the core decodes
// them as illegal instructions so they never get here.
// =====================================================================
`default_nettype none

module alu #(
    parameter M_EXT    = 1,
    parameter DIV_ITER = 0,    // 1: no array dividers here; div_iter does DIV/DIVU/REM/REMU
    parameter MUL_2C   = 0     // 1: no multipliers here; mul_2c does MUL/MULH/MULHSU/MULHU
) (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [4:0]  alu_op,
    output reg  [31:0] result,
    output wire        zero
);
    // ---- base integer ops ----
    localparam ALU_ADD =5'd0,  ALU_SUB =5'd1,  ALU_AND =5'd2,  ALU_OR  =5'd3,
               ALU_XOR =5'd4,  ALU_SLL =5'd5,  ALU_SRL =5'd6,  ALU_SRA =5'd7,
               ALU_SLT =5'd8,  ALU_SLTU=5'd9;
    // ---- RV32M ops ----
    localparam ALU_MUL   =5'd10, ALU_MULH =5'd11, ALU_MULHSU=5'd12,
               ALU_MULHU =5'd13, ALU_DIV  =5'd14, ALU_DIVU  =5'd15,
               ALU_REM   =5'd16, ALU_REMU =5'd17;

    wire [4:0] shamt = b[4:0];

    // RV32M operands: constant zero when M_EXT=0, so synthesis folds the
    // multipliers and dividers away entirely (gating only the result mux
    // would leave them built -- the tool cannot see alu_op never selects them)
    wire [31:0] ma = M_EXT ? a : 32'd0;
    wire [31:0] mb = M_EXT ? b : 32'd0;
    // ... and the same for the divider's operands when DIV_ITER takes the
    // division elsewhere (0 / 1, which folds; not 0 / 0)
    wire [31:0] da = DIV_ITER ? 32'd0 : ma;
    wire [31:0] db = DIV_ITER ? 32'd1 : mb;
    // ... and the multipliers' when MUL_2C takes the multiplies elsewhere
    wire [31:0] xa = MUL_2C ? 32'd0 : ma;
    wire [31:0] xb = MUL_2C ? 32'd0 : mb;

    // 64-bit products for the high-multiply variants.
    wire signed [63:0] a_s  = $signed({{32{xa[31]}}, xa}); // a as signed64
    wire signed [63:0] b_s  = $signed({{32{xb[31]}}, xb}); // b as signed64
    wire        [63:0] a_u  = {32'b0, xa};                 // a as unsigned64
    wire        [63:0] b_u  = {32'b0, xb};                 // b as unsigned64
    wire signed [63:0] p_ss = a_s * b_s;                   // signed   x signed
    wire        [63:0] p_uu = a_u * b_u;                   // unsigned x unsigned
    wire signed [63:0] p_su = a_s * $signed(b_u);          // signed   x unsigned

    // Division with RV32M special cases.
    wire        div0   = (mb == 32'd0);
    wire        ovf    = (ma == 32'h8000_0000) && (mb == 32'hFFFF_FFFF);
    wire signed [31:0] sa = $signed(da);
    wire signed [31:0] sb = $signed(db);
    // Evaluate signed divide/remainder in their own signed context. If
    // mixed with unsigned operands inside a ?: below, Verilog would treat
    // the whole expression as unsigned -- so compute them here first.
    wire signed [31:0] q_s = sa / sb;
    wire signed [31:0] r_s = sa % sb;

    always @(*) begin
        if (M_EXT == 0 && alu_op >= ALU_MUL) result = 32'd0;
        else case (alu_op)
            ALU_ADD : result = a + b;
            ALU_SUB : result = a - b;
            ALU_AND : result = a & b;
            ALU_OR  : result = a | b;
            ALU_XOR : result = a ^ b;
            ALU_SLL : result = a << shamt;
            ALU_SRL : result = a >> shamt;
            ALU_SRA : result = $signed(a) >>> shamt;
            ALU_SLT : result = ($signed(a) <  $signed(b)) ? 32'd1 : 32'd0;
            ALU_SLTU: result = (a < b) ? 32'd1 : 32'd0;

            ALU_MUL   : result = p_ss[31:0];      // low 32 (same for all signs)
            ALU_MULH  : result = p_ss[63:32];
            ALU_MULHSU: result = p_su[63:32];
            ALU_MULHU : result = p_uu[63:32];

            ALU_DIV : result = div0 ? 32'hFFFF_FFFF
                              : ovf  ? 32'h8000_0000
                              : q_s;
            ALU_DIVU: result = div0 ? 32'hFFFF_FFFF : (da / db);
            ALU_REM : result = div0 ? a
                              : ovf  ? 32'd0
                              : r_s;
            ALU_REMU: result = div0 ? a : (da % db);

            default : result = 32'd0;
        endcase
    end

    assign zero = (result == 32'd0);
endmodule

// =====================================================================
// div_iter  -  iterative RV32M divider: one quotient bit per cycle
// (in this file so that every build with an ALU has it)
// ---------------------------------------------------------------------
// alu.v writes DIV / DIVU / REM / REMU as Verilog / and %. That is one
// combinational array divider per operator: on a Zynq-7010 it is most of
// the design's logic, and nearly all of its carry chains (Step 57). This
// is the small alternative, selected by cpu_pipe_u's DIV_ITER parameter:
// a restoring divider on the unsigned magnitudes, 32 cycles, with the
// signs and RV32M's special cases applied around it.
//
// The handshake is the one cpu_pipe_u already has for a vector op:
//   want   an instruction of this kind is in EX (idex_valid & a divide op)
//   go     it leaves EX this cycle (ex_go), or is killed
//   done   the result is ready; while want & ~done the pipeline holds EX
//
//   IDLE --want & start--> RUN (32 cycles) --> DONE --go | ~want--> IDLE
//
// A killed instruction (a flush or a trap while RUN) drops `want`, which
// returns the unit to IDLE. The operands are latched on the first cycle,
// so the pipeline's forwarding network may change under it afterwards.
//
// op: 0 DIV, 1 DIVU, 2 REM, 3 REMU (the low two bits of alu_op - 14).
// Results, RV32M section 7.2: x/0 = -1 and x%0 = x; the one signed
// overflow, -2^31 / -1, gives 2^31 and remainder 0.
// =====================================================================
module div_iter (
    input  wire        clk,
    input  wire        rst,
    input  wire        want,
    input  wire        start_ok,       // the operands are valid this cycle (~freeze)
    input  wire        go,
    input  wire [1:0]  op,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire        done,
    output wire [31:0] result
);
    localparam IDLE = 2'd0, RUN = 2'd1, DONE = 2'd2;
    reg [1:0]  state;
    reg [5:0]  cnt;
    reg [31:0] q;            // the dividend's bits shift out of the top as the quotient's shift in
    reg [31:0] r;            // partial remainder
    reg [31:0] d;            // |divisor|
    reg [31:0] a0;           // the original dividend (x % 0 = x)
    reg        is_rem, div0, ovf, neg_q, neg_r;

    wire        sgn    = ~op[0];
    wire        a_neg  = sgn & a[31];
    wire        b_neg  = sgn & b[31];
    wire [31:0] a_abs  = a_neg ? -a : a;
    wire [31:0] b_abs  = b_neg ? -b : b;

    wire [32:0] r2     = {r, q[31]};
    wire        ge     = r2 >= {1'b0, d};
    wire [32:0] r2_sub = r2 - {1'b0, d};

    always @(posedge clk) begin
        if (rst) state <= IDLE;
        else case (state)
            IDLE: if (want && start_ok) begin
                state  <= RUN;
                cnt    <= 6'd31;
                q      <= a_abs;
                r      <= 32'd0;
                d      <= b_abs;
                a0     <= a;
                is_rem <= op[1];
                div0   <= (b == 32'd0);
                ovf    <= sgn && (a == 32'h8000_0000) && (b == 32'hFFFF_FFFF);
                neg_q  <= a_neg ^ b_neg;
                neg_r  <= a_neg;
            end
            RUN: begin
                if (!want) state <= IDLE;
                else begin
                    r <= ge ? r2_sub[31:0] : r2[31:0];
                    q <= {q[30:0], ge};
                    cnt <= cnt - 6'd1;
                    if (cnt == 6'd0) state <= DONE;
                end
            end
            default: if (go || !want) state <= IDLE;
        endcase
    end

    assign done   = (state == DONE);
    assign result = div0 ? (is_rem ? a0 : 32'hFFFF_FFFF) :
                    ovf  ? (is_rem ? 32'd0 : 32'h8000_0000) :
                    is_rem ? (neg_r ? -r : r) :
                             (neg_q ? -q : q);
endmodule

// =====================================================================
// mul_2c  -  RV32M multiplies with registers on both sides of the DSPs
// ---------------------------------------------------------------------
// alu.v's three combinational 32x32 products put two DSP48s in series, and
// the adder that sums their partial products, between the forwarding
// network and everything downstream of the ALU (Step 57's critical path ran
// forwarding -> multiplier -> ALU result -> address -> D-TLB -> fault).
// Selected by cpu_pipe_u's MUL_2C parameter, this unit holds EX for two
// cycles: the first latches the operands, the second multiplies the
// latched operands into a result register, the third presents it. One
// signed 33x33 multiply covers all four: an operand is sign-extended where
// the instruction treats it as signed, zero-extended otherwise.
//
// The handshake is div_iter's: want (a multiply is in EX), start_ok (the
// operands are valid: ~freeze), go (it leaves EX), done. Dropping `want`
// aborts.
//
// op: 0 MUL, 1 MULH, 2 MULHSU, 3 MULHU (alu_op - 10).
// =====================================================================
module mul_2c (
    input  wire        clk,
    input  wire        rst,
    input  wire        want,
    input  wire        start_ok,
    input  wire        go,
    input  wire [1:0]  op,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire        done,
    output wire [31:0] result
);
    localparam IDLE = 2'd0, MULT = 2'd1, DONE = 2'd2;
    reg [1:0]  state;
    reg [32:0] ra, rb;
    reg        hi;
    reg [31:0] res;
    wire signed [65:0] p = $signed(ra) * $signed(rb);

    always @(posedge clk) begin
        if (rst) state <= IDLE;
        else case (state)
            IDLE: if (want && start_ok) begin
                ra    <= {(op != 2'd3) & a[31], a};                   // signed but in MULHU
                rb    <= {((op == 2'd0) | (op == 2'd1)) & b[31], b};  // signed in MUL, MULH
                hi    <= (op != 2'd0);
                state <= MULT;
            end
            MULT: begin
                if (!want) state <= IDLE;
                else begin
                    res   <= hi ? p[63:32] : p[31:0];
                    state <= DONE;
                end
            end
            default: if (go || !want) state <= IDLE;
        endcase
    end

    assign done   = (state == DONE);
    assign result = res;
endmodule

`default_nettype wire
