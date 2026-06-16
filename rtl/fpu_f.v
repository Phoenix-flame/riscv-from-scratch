// =====================================================================
// fpu_f.v  -  Single-precision (F) floating-point unit
// ---------------------------------------------------------------------
// One unit behind a start/done handshake. add/sub/mul/sgnj/minmax/cmp/class/
// cvt/mv resolve in two cycles; div and sqrt model a multi-cycle latency.
// A shared rounder turns an unrounded significand (24-bit kept field + guard/
// round/sticky) into a correctly rounded IEEE-754 single in any of the five
// rounding modes, raising inexact/overflow/underflow.
//
// SCOPE (honest accounting in the step doc):
//   * Zero, inf, NaN, signed zero per IEEE-754; quiet-NaN propagation and the
//     standard NV signalling on invalid ops.
//   * Subnormals flushed to zero on input and output (FTZ/DAZ). Keeps every
//     normal-range result bit-exact against a host float32; drops only the
//     denormal band near zero.
//   * `to_int` marks results that target the integer regfile
//     (compare / classify / fcvt.w[u].s / fmv.x.w).
//
// op: 0 ADD 1 SUB 2 MUL 3 DIV 4 SQRT 5 SGNJ 6 MINMAX 7 CMP 8 CVT_WS 9 CVT_WUS
//     10 CVT_SW 11 CVT_SWU 12 FMV_X_W 13 FMV_W_X 14 FCLASS
// fmt3=funct3 (sgnj j/jn/jx, min/max, cmp le/lt/eq); rm = rounding mode.
// =====================================================================
`default_nettype none

module fpu_f (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [3:0]  op,
    input  wire [2:0]  fmt3,
    input  wire [2:0]  rm,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg  [31:0] result,
    output reg         to_int,
    output reg  [4:0]  flags,
    output reg         done,
    output wire        busy
);
    localparam ADD=0, SUB=1, MUL=2, DIV=3, SQRT=4, SGNJ=5, MINMAX=6, CMP=7,
               CVT_WS=8, CVT_WUS=9, CVT_SW=10, CVT_SWU=11, FMV_X_W=12,
               FMV_W_X=13, FCLASS=14;
    localparam RNE=3'b000, RTZ=3'b001, RDN=3'b010, RUP=3'b011, RMM=3'b100;
    localparam [31:0] CANON_QNAN = 32'h7FC00000;

    wire        sa = a[31],          sb = b[31];
    wire [7:0]  ea = a[30:23],       eb = b[30:23];
    wire [22:0] fa = a[22:0],        fb = b[22:0];
    wire a_zero = (ea==0);
    wire b_zero = (eb==0);
    wire a_inf  = (ea==255)&&(fa==0), b_inf = (eb==255)&&(fb==0);
    wire a_nan  = (ea==255)&&(fa!=0), b_nan = (eb==255)&&(fb!=0);
    wire a_snan = a_nan && !fa[22],   b_snan = b_nan && !fb[22];
    wire [23:0] ma = a_zero ? 24'd0 : {1'b1, fa};
    wire [23:0] mb = b_zero ? 24'd0 : {1'b1, fb};

    function [34:0] round_pack;        // {of, uf, nx, float[31:0]}
        input        s;
        input signed [9:0] exp_in;
        input [26:0] sig;
        input [2:0]  mode;
        reg   [23:0] keep; reg g,r,st,lsb,inc; reg signed [9:0] e;
        reg   [24:0] keep_c; reg of,uf,nx; reg [31:0] f32;
        begin
            e=exp_in; keep=sig[26:3]; g=sig[2]; r=sig[1]; st=sig[0]; lsb=sig[3];
            nx = g | r | st;
            case (mode)
                RNE: inc = g & (r | st | lsb);
                RTZ: inc = 1'b0;
                RDN: inc = s & (g | r | st);
                RUP: inc = (~s) & (g | r | st);
                RMM: inc = g;
                default: inc = g & (r | st | lsb);
            endcase
            keep_c = {1'b0, keep} + (inc ? 25'd1 : 25'd0);
            if (keep_c[24]) begin keep_c = keep_c >> 1; e = e + 1; end
            of=0; uf=0;
            if (e >= 255) begin
                of=1; nx=1;
                if ((mode==RTZ) || (mode==RDN && ~s) || (mode==RUP && s))
                    f32 = {s, 8'd254, 23'h7FFFFF};
                else
                    f32 = {s, 8'd255, 23'd0};
            end else if (e <= 0) begin
                uf = (keep_c[23:0] != 0); nx = nx | uf;
                f32 = {s, 31'd0};
            end else
                f32 = {s, e[7:0], keep_c[22:0]};
            round_pack = {of, uf, nx, f32};
        end
    endfunction

    function [4:0] lzc27;
        input [26:0] x; integer k; reg d;
        begin lzc27=27; d=0;
            for (k=26;k>=0;k=k-1) if(!d && x[k]) begin lzc27=26-k; d=1; end end
    endfunction

    reg [31:0] cres; reg c_toint; reg [4:0] cflags;

    task do_addsub;
        input is_sub;
        reg s2,rs,big_s; reg [7:0] e_big; reg signed [9:0] ediff,eres;
        reg [23:0] m_big,m_small; reg [26:0] big_ext,small_ext,small_sh,small_lost;
        reg sticky; reg [27:0] sum; reg [26:0] sig; reg [4:0] shamt; reg [34:0] rp;
        begin
            s2 = sb ^ is_sub;
            if (a_nan || b_nan) begin cres=CANON_QNAN; cflags={(a_snan|b_snan),4'b0};
            end else if (a_inf && b_inf) begin
                if (sa!=s2) begin cres=CANON_QNAN; cflags=5'b10000; end
                else        begin cres={sa,8'd255,23'd0}; cflags=0; end
            end else if (a_inf) begin cres={sa,8'd255,23'd0}; cflags=0;
            end else if (b_inf) begin cres={s2,8'd255,23'd0}; cflags=0;
            end else if (a_zero && b_zero) begin
                rs = (sa & s2) | ((rm==RDN) & (sa | s2)); cres={rs,31'd0}; cflags=0;
            end else if (a_zero) begin cres={s2,eb,fb}; cflags=0;
            end else if (b_zero) begin cres={sa,ea,fa}; cflags=0;
            end else begin
                if (ea>=eb) begin e_big=ea; big_s=sa; m_big=ma; m_small=mb; ediff=ea-eb; end
                else        begin e_big=eb; big_s=s2; m_big=mb; m_small=ma; ediff=eb-ea; end
                big_ext   = {m_big, 3'b000};
                small_ext = {m_small, 3'b000};
                if (ediff >= 27) begin small_sh=0; sticky=(small_ext!=0); end
                else begin
                    small_sh   = small_ext >> ediff;
                    small_lost = small_ext << (27 - ediff);
                    sticky     = |small_lost;
                end
                small_sh[0] = small_sh[0] | sticky;
                if (sa == s2) begin
                    sum = {1'b0,big_ext} + {1'b0,small_sh}; rs = big_s;
                    if (sum[27]) begin sig=sum[27:1]; sig[0]=sig[0]|sum[0]; eres=e_big+1; end
                    else         begin sig=sum[26:0];                       eres=e_big;   end
                    rp = round_pack(rs,eres,sig,rm);
                    cres=rp[31:0]; cflags={1'b0,rp[34],rp[33],1'b0,rp[32]};
                end else begin
                    if (big_ext >= small_sh) begin sum={1'b0,big_ext}-{1'b0,small_sh}; rs=big_s; end
                    else                      begin sum={1'b0,small_sh}-{1'b0,big_ext}; rs=~big_s; end
                    if (sum[26:0]==0) begin cres={(rm==RDN),31'd0}; cflags=0; end
                    else begin
                        shamt = lzc27(sum[26:0]); sig = sum[26:0] << shamt; eres = e_big - shamt;
                        rp = round_pack(rs,eres,sig,rm);
                        cres=rp[31:0]; cflags={1'b0,rp[34],rp[33],1'b0,rp[32]};
                    end
                end
            end
        end
    endtask

    task do_mul;
        reg s; reg signed [9:0] e; reg [47:0] prod; reg [26:0] sig; reg [34:0] rp;
        begin
            s = sa ^ sb;
            if (a_nan || b_nan) begin cres=CANON_QNAN; cflags={(a_snan|b_snan),4'b0};
            end else if ((a_inf&&b_zero)||(b_inf&&a_zero)) begin cres=CANON_QNAN; cflags=5'b10000;
            end else if (a_inf||b_inf) begin cres={s,8'd255,23'd0}; cflags=0;
            end else if (a_zero||b_zero) begin cres={s,31'd0}; cflags=0;
            end else begin
                prod = ma * mb;
                e = $signed({2'b0,ea}) + $signed({2'b0,eb}) - 127;
                if (prod[47]) begin sig={prod[47:22], |prod[21:0]}; e=e+1; end
                else          begin sig={prod[46:21], |prod[20:0]};         end
                rp = round_pack(s,e,sig,rm);
                cres=rp[31:0]; cflags={1'b0,rp[34],rp[33],1'b0,rp[32]};
            end
        end
    endtask

    function [36:0] fdiv_core;
        input dummy;
        reg s; reg signed [9:0] e; reg [49:0] num; reg [24:0] rem; reg [26:0] quo;
        reg st; reg [26:0] sig; reg [34:0] rp; integer i;
        begin
            s = sa ^ sb;
            if (a_nan||b_nan)        fdiv_core = {{(a_snan|b_snan),4'b0}, CANON_QNAN};
            else if (a_inf&&b_inf)   fdiv_core = {5'b10000, CANON_QNAN};
            else if (a_zero&&b_zero) fdiv_core = {5'b10000, CANON_QNAN};
            else if (a_inf)          fdiv_core = {5'b0, {s,8'd255,23'd0}};
            else if (b_inf)          fdiv_core = {5'b0, {s,31'd0}};
            else if (b_zero)         fdiv_core = {5'b01000, {s,8'd255,23'd0}};
            else if (a_zero)         fdiv_core = {5'b0, {s,31'd0}};
            else begin
                num = {ma, 26'd0};
                rem = 0; quo = 0;
                for (i=49; i>=0; i=i-1) begin
                    rem = {rem[23:0], num[i]};
                    quo = quo << 1;
                    if (rem >= {1'b0, mb}) begin rem = rem - {1'b0, mb}; quo[0]=1'b1; end
                end
                st = (rem != 0);
                e = $signed({2'b0,ea}) - $signed({2'b0,eb}) + 127;
                if (quo[26]) begin sig = {quo[26:1], (quo[0]|st)};            end
                else         begin sig = {quo[25:0], st};          e = e - 1; end
                rp = round_pack(s, e, sig, rm);
                fdiv_core = {{1'b0,rp[34],rp[33],1'b0,rp[32]}, rp[31:0]};
            end
        end
    endfunction

    function [36:0] fsqrt_core;
        input dummy;
        reg signed [9:0] e; reg [55:0] rad; reg [55:0] bit_; reg [55:0] res;
        reg st; reg [26:0] sig; reg [34:0] rp; reg [24:0] mscaled;
        begin
            if (a_nan)        fsqrt_core = {{a_snan,4'b0}, CANON_QNAN};
            else if (a_zero)  fsqrt_core = {5'b0, {sa,31'd0}};
            else if (sa)      fsqrt_core = {5'b10000, CANON_QNAN};
            else if (a_inf)   fsqrt_core = {5'b0, {1'b0,8'd255,23'd0}};
            else begin
                // (ea-127) odd <=> ea even (ea[0]==0). Then use m_adj = 2m.
                mscaled = (~ea[0]) ? {ma, 1'b0} : {1'b0, ma};
                rad = {7'd0, mscaled, 24'd0};       // mscaled << 24
                rad = rad << 5;                     // total << 29
                res = 0; bit_ = 56'd1 << 54;
                while (bit_ > rad) bit_ = bit_ >> 2;
                while (bit_ != 0) begin
                    if (rad >= res + bit_) begin rad = rad - (res + bit_); res = (res>>1)+bit_; end
                    else res = res >> 1;
                    bit_ = bit_ >> 2;
                end
                st = (rad != 0);
                e = ($signed({2'b0,ea}) - 127);
                e = (e >>> 1) + 127;
                sig = {res[26:1], (res[0]|st)};
                rp  = round_pack(1'b0, e, sig, rm);
                fsqrt_core = {{1'b0,rp[34],rp[33],1'b0,rp[32]}, rp[31:0]};
            end
        end
    endfunction

    task do_simple;
        reg [31:0] r; reg [4:0] fl; reg lt,eq,less,s; reg [9:0] sh; reg [54:0] big;
        reg [31:0] ui; reg [26:0] sig; reg [34:0] rp; reg [7:0] e; integer k;
        begin
            r=0; fl=0; c_toint=0;
            case (op)
            SGNJ: case (fmt3)
                3'b000:  r = {sb,      a[30:0]};
                3'b001:  r = {~sb,     a[30:0]};
                default: r = {sa^sb,   a[30:0]};
            endcase
            MINMAX: begin
                if (a_nan && b_nan) r = CANON_QNAN;
                else if (a_nan)     r = b;
                else if (b_nan)     r = a;
                else begin
                    if (a[31]!=b[31]) less = a[31] && !(a_zero&&b_zero);
                    else if (!a[31])  less = (a[30:0] < b[30:0]);
                    else              less = (a[30:0] > b[30:0]);
                    if (fmt3==3'b000) r = less ? a : b; else r = less ? b : a;
                end
                if (a_snan||b_snan) fl = 5'b10000;
            end
            CMP: begin c_toint=1;
                if (a_nan || b_nan) begin
                    fl = (((fmt3==3'b010)?(a_snan|b_snan):(a_nan|b_nan)) ? 5'b10000:5'b0); r=0;
                end else begin
                    eq = (a==b) || (a_zero&&b_zero);
                    if (a[31]!=b[31]) lt = a[31] && !(a_zero&&b_zero);
                    else if (!a[31])  lt = (a[30:0] < b[30:0]);
                    else              lt = (a[30:0] > b[30:0]);
                    case (fmt3) 3'b010:r={31'd0,eq}; 3'b001:r={31'd0,lt}; default:r={31'd0,lt|eq}; endcase
                end
            end
            FCLASS: begin c_toint=1;
                if      (a_nan)           r = a_snan ? 32'h100 : 32'h200;
                else if (a_inf)           r = sa ? 32'h001 : 32'h080;
                else if (a_zero && fa==0) r = sa ? 32'h008 : 32'h010;
                else if (a_zero)          r = sa ? 32'h004 : 32'h020;
                else                      r = sa ? 32'h002 : 32'h040;
            end
            FMV_X_W: begin c_toint=1; r=a; end
            FMV_W_X: r=a;
            CVT_WS, CVT_WUS: begin c_toint=1;
                if (a_nan) begin r=(op==CVT_WS)?32'h7FFFFFFF:32'hFFFFFFFF; fl=5'b10000;
                end else if (a_zero) r=0;
                else begin
                    e = ea;
                    if (e < 127) begin
                        r=0; fl=5'b00001;
                        if (op==CVT_WUS && sa) begin r=0; fl=5'b10000; end
                    end else begin
                        sh = e - 127;
                        if (sh >= 31) begin
                            if (op==CVT_WS) r = sa?32'h80000000:32'h7FFFFFFF;
                            else            r = sa?32'd0:32'hFFFFFFFF;
                            fl=5'b10000;
                        end else begin
                            big = {31'd0, ma} << sh; ui = big[54:23];
                            if (|big[22:0]) fl=5'b00001;
                            if (op==CVT_WS) begin
                                r = sa ? (~ui + 1) : ui;
                                if (!sa && ui[31]) begin r=32'h7FFFFFFF; fl=5'b10000; end
                                if ( sa && (ui > 32'h80000000)) begin r=32'h80000000; fl=5'b10000; end
                            end else r = sa ? 32'd0 : ui;
                        end
                    end
                end
            end
            CVT_SW, CVT_SWU: begin
                if (a==0) r=0;
                else begin
                    s = (op==CVT_SW) ? a[31] : 1'b0;
                    ui = (op==CVT_SW && a[31]) ? (~a + 1) : a;
                    sh = 0;
                    for (k=31;k>=0;k=k-1) if (sh==0 && ui[k]) sh=k;
                    e = sh + 127;
                    if (sh <= 23) begin
                        sig = {ui, 3'b000} << (23 - sh);
                    end else begin
                        sig = 0;
                        sig[26:3] = ui >> (sh - 23);
                        sig[2]    = (ui >> (sh - 24)) & 1'b1;
                        sig[1]    = (sh>=25) ? ((ui >> (sh-25)) & 1'b1) : 1'b0;
                        sig[0]    = (sh>=25) ? (|(ui & ((32'd1 << (sh-25)) - 1))) : 1'b0;
                    end
                    rp = round_pack(s, e, sig, rm);
                    r = rp[31:0]; fl = {1'b0,rp[34],rp[33],1'b0,rp[32]};
                end
            end
            default: r=0;
            endcase
            cres=r; cflags=fl;
        end
    endtask

    reg [3:0] state; localparam IDLE=0, GO=1, WAITN=2;
    reg [5:0] waitc;
    reg [36:0] dv, sq;
    assign busy = (state != IDLE);

    always @(posedge clk) begin
        if (rst) begin state<=IDLE; done<=0; result<=0; flags<=0; to_int<=0; end
        else begin
            done <= 0;
            case (state)
            IDLE: if (start) begin
                case (op)
                ADD: begin do_addsub(0); result<=cres; flags<=cflags; to_int<=0; state<=GO; end
                SUB: begin do_addsub(1); result<=cres; flags<=cflags; to_int<=0; state<=GO; end
                MUL: begin do_mul();     result<=cres; flags<=cflags; to_int<=0; state<=GO; end
                DIV: begin dv=fdiv_core(0);  result<=dv[31:0]; flags<=dv[36:32]; to_int<=0; waitc<=26; state<=WAITN; end
                SQRT:begin sq=fsqrt_core(0); result<=sq[31:0]; flags<=sq[36:32]; to_int<=0; waitc<=26; state<=WAITN; end
                default: begin do_simple(); result<=cres; flags<=cflags; to_int<=c_toint; state<=GO; end
                endcase
            end
            GO: begin done<=1; state<=IDLE; end
            WAITN: begin if (waitc==0) begin done<=1; state<=IDLE; end else waitc<=waitc-1; end
            default: state<=IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
