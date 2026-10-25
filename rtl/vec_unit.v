// =====================================================================
// vec_unit.v  -  RISC-V vector extension: Zve32x (Step 47)
// ---------------------------------------------------------------------
// The integer vector profile for a core without 64-bit elements or FP:
// ELEN = 32, VLEN a parameter (64 / 128 / 256). It is a *blocking*,
// *element-serial* unit: while it executes, the instruction stays in EX
// (the pipeline holds it there exactly like a D-TLB walk, Step 42), and
// the unit walks the active elements one per cycle -- one VRF read of
// every operand, one ALU/multiplier operation, one VRF write. Memory
// instructions do one element access per cycle on the core's D-port,
// each element translated through the core's D-TLB / walker, so vector
// code runs translated in S/U mode like any other code.
//
// Implemented (everything else in the vector encoding space is illegal):
//   config   vsetvli vsetivli vsetvl (the core does these in EX)
//            SEW 8/16/32, LMUL 1/8..8, vta/vma (treated as undisturbed)
//   memory   vle/vse{8,16,32} [masked], vlse/vsse (strided),
//            vluxei/vloxei/vsuxei/vsoxei (indexed), vlm/vsm, vle*ff
//            (fault-only-first), vl<n>re*/vs<n>r (whole register)
//   integer  vadd vsub vrsub vand vor vxor vsll vsrl vsra
//            vminu vmin vmaxu vmax vmerge vmv.v.[vxi] vmv<n>r.v
//            vmseq vmsne vmsltu vmslt vmsleu vmsle vmsgtu vmsgt
//            vmul vmulh vmulhu vmulhsu vmacc vnmsac vmadd vnmsub
//            vslideup vslidedown vslide1up vslide1down
//   reduce   vredsum vredand vredor vredxor vredminu vredmin vredmaxu vredmax
//   mask     vmand vmnand vmandn vmxor vmor vmnor vmorn vmxnor
//            vcpop.m vfirst.m vid.v
//   moves    vmv.x.s vmv.s.x
//   CSRs     vstart vxsat vxrm vcsr vl vtype vlenb
// Not implemented: fixed-point arithmetic (vsadd, vaadd, vsmul, vssr*,
// vnclip -- part of Zve32x), divide, widening/narrowing, segment
// loads/stores, vrgather, vcompress, viota and the vmsbf family.
//
// Tail and masked-off elements are always left undisturbed (legal for
// both the "undisturbed" and the "agnostic" policies). A memory fault at
// element i writes vstart = i and traps precisely: elements below i are
// done, the rest untouched, and re-executing the instruction resumes at
// i. vle*ff instead trims vl when the fault is not at element 0.
// =====================================================================
`default_nettype none

module vec_unit #(
    parameter VLEN = 128
) (
    input  wire        clk,
    input  wire        rst,

    // ---- the instruction in EX ----
    input  wire [31:0] instr,
    input  wire        start,          // begin executing `instr` (one cycle)
    input  wire [31:0] rs1_val,        // scalar operands, sampled at start
    input  wire [31:0] rs2_val,
    output wire        is_vec,         // instr is in the vector encoding space
    output wire        is_cfg,         // ... a vsetvl* (done by the core in EX)
    output wire        illegal,        // ... and not executable in the current state
    output wire        writes_rd,      // vsetvl*, vmv.x.s, vcpop.m, vfirst.m
    output wire        busy,
    output reg         done,           // one-cycle: the instruction is finished
    output reg         fault,          // ... with a memory fault (valid with done)
    output reg  [3:0]  fault_cause,    // 13 load / 15 store page fault
    output reg  [31:0] fault_tval,
    output reg  [31:0] scalar_out,     // rd value (valid with done)
    output wire        vs_dirty,       // vector state written (with done / cfg)

    // ---- vsetvl* (the core computes rd = new vl in EX) ----
    output wire [31:0] cfg_new_vl,
    input  wire        cfg_commit,
    input  wire        vs_on,          // mstatus.VS != Off

    // ---- CSR port ----
    input  wire [11:0] csr_addr,
    output reg         csr_hit,
    output reg  [31:0] csr_rdata,
    input  wire        csr_we,         // commit: write csr_wdata
    input  wire [31:0] csr_wdata,

    // ---- memory: one element access at a time, translated by the core ----
    output wire [31:0] mem_va,         // element virtual address
    output wire        mem_store,
    output wire        mem_active,     // a memory instruction is running
    output wire        mem_want,       // the current element needs an access
    output wire        mem_req,        // issue the access now (core grants)
    output wire [3:0]  mem_be,
    output wire [31:0] mem_wdata,
    input  wire [31:0] mem_rdata,
    input  wire        mem_done,       // the access completed this cycle
    input  wire        xl_ok,          // translation of mem_va ready (or off)
    input  wire        xl_fault        // translation of mem_va faults
);
    localparam WPR  = VLEN / 32;                 // words per vector register
    localparam LWPR = $clog2(WPR);
    localparam NW   = 32 * WPR;
    localparam AW   = $clog2(NW);
    localparam LVB  = $clog2(VLEN / 8);          // log2 vlenb

    // =================================================================
    // architectural state
    // =================================================================
    reg [31:0] vrf [0:NW-1];
    reg [31:0] vl, vtype, vstart;
    reg [1:0]  vxrm;
    reg        vxsat;
    integer k;
    initial for (k = 0; k < NW; k = k + 1) vrf[k] = 32'd0;

    wire        vill     = vtype[31];
    wire [2:0]  vsew     = vtype[5:3];
    wire [2:0]  vlmul    = vtype[2:0];
    wire [1:0]  sewl     = vsew[1:0];             // log2(SEW/8): 0, 1, 2
    // log2 LMUL as a signed value, -3 .. 3
    wire signed [3:0] lmull = vlmul[2] ? $signed({1'b1, vlmul}) : $signed({1'b0, vlmul});

    // =================================================================
    // decode
    // =================================================================
    wire [6:0] op  = instr[6:0];
    wire [2:0] f3  = instr[14:12];
    wire [5:0] f6  = instr[31:26];
    wire       vm  = instr[25];
    wire [4:0] rs2f= instr[24:20];               // vs2 / rs2 / lumop
    wire [4:0] rs1f= instr[19:15];               // vs1 / rs1 / simm5
    wire [4:0] vd  = instr[11:7];

    wire is_opv = (op == 7'b1010111);
    wire is_ld  = (op == 7'b0000111) && (f3 == 3'b000 || f3[2]);
    wire is_st  = (op == 7'b0100111) && (f3 == 3'b000 || f3[2]);
    assign is_vec = is_opv | is_ld | is_st;
    assign is_cfg = is_opv && f3 == 3'b111;

    wire ivv = is_opv && f3 == 3'b000, ivi = is_opv && f3 == 3'b011, ivx = is_opv && f3 == 3'b100;
    wire mvv = is_opv && f3 == 3'b010, mvx = is_opv && f3 == 3'b110;
    wire iv  = ivv | ivi | ivx;

    // ---- arithmetic classes ----
    localparam C_NONE=5'd0, C_ARITH=5'd1, C_CMP=5'd2, C_MLOG=5'd3, C_RED=5'd4, C_MVXS=5'd5,
               C_MVSX=5'd6, C_CPOP=5'd7, C_FIRST=5'd8, C_VID=5'd9, C_SLUP=5'd10, C_SLDN=5'd11,
               C_SL1UP=5'd12, C_SL1DN=5'd13, C_MVNR=5'd14, C_LD=5'd15, C_ST=5'd16;
    reg [4:0] cls;
    reg       ok;                                 // a supported encoding
    always @(*) begin
        cls = C_NONE; ok = 1'b0;
        if (iv) case (f6)
            6'b000000, 6'b001001, 6'b001010, 6'b001011, 6'b100101, 6'b101000, 6'b101001:
                begin cls = C_ARITH; ok = 1; end                       // add and or xor sll srl sra
            6'b000010, 6'b000100, 6'b000101, 6'b000110, 6'b000111:
                begin cls = C_ARITH; ok = ~ivi; end                    // sub minu min maxu max
            6'b000011: begin cls = C_ARITH; ok = ~ivv; end            // rsub
            6'b010111: begin cls = C_ARITH; ok = vm ? (rs2f == 5'd0) : (vd != 5'd0); end  // vmv.v / vmerge
            6'b011000, 6'b011001, 6'b011100, 6'b011101: begin cls = C_CMP; ok = 1; end
            6'b011010, 6'b011011: begin cls = C_CMP; ok = ~ivi; end
            6'b011110, 6'b011111: begin cls = C_CMP; ok = ~ivv; end
            6'b001110: begin cls = C_SLUP; ok = ~ivv; end
            6'b001111: begin cls = C_SLDN; ok = ~ivv; end
            6'b100111: begin cls = C_MVNR; ok = ivi && vm &&
                                 (rs1f == 5'd0 || rs1f == 5'd1 || rs1f == 5'd3 || rs1f == 5'd7); end
            default: ;
        endcase
        else if (mvv) case (f6)
            6'b000000, 6'b000001, 6'b000010, 6'b000011, 6'b000100, 6'b000101, 6'b000110, 6'b000111:
                begin cls = C_RED; ok = 1; end
            6'b010000: case (rs1f)
                5'b00000: begin cls = C_MVXS;  ok = vm; end
                5'b10000: begin cls = C_CPOP;  ok = 1; end
                5'b10001: begin cls = C_FIRST; ok = 1; end
                default: ;
            endcase
            6'b010100: if (rs1f == 5'b10001) begin cls = C_VID; ok = (rs2f == 5'd0); end
            6'b011000, 6'b011001, 6'b011010, 6'b011011, 6'b011100, 6'b011101, 6'b011110, 6'b011111:
                begin cls = C_MLOG; ok = vm; end
            6'b100100, 6'b100101, 6'b100110, 6'b100111, 6'b101001, 6'b101011, 6'b101101, 6'b101111:
                begin cls = C_ARITH; ok = 1; end
            default: ;
        endcase
        else if (mvx) case (f6)
            6'b010000: begin cls = C_MVSX; ok = vm && rs2f == 5'd0; end
            6'b001110: begin cls = C_SL1UP; ok = 1; end
            6'b001111: begin cls = C_SL1DN; ok = 1; end
            6'b100100, 6'b100101, 6'b100110, 6'b100111, 6'b101001, 6'b101011, 6'b101101, 6'b101111:
                begin cls = C_ARITH; ok = 1; end
            default: ;
        endcase
        else if (is_ld) begin cls = C_LD; ok = 1; end
        else if (is_st) begin cls = C_ST; ok = 1; end
    end

    // ---- memory instruction fields ----
    wire [2:0] nf  = instr[31:29];
    wire       mew = instr[28];
    wire [1:0] mop = instr[27:26];               // 00 unit 01 idx-unord 10 strided 11 idx-ord
    wire       m_unit = (mop == 2'b00), m_strd = (mop == 2'b10), m_idx = mop[0];
    wire [1:0] weewl = (f3 == 3'b000) ? 2'd0 : (f3 == 3'b101) ? 2'd1 : 2'd2;   // 8/16/32
    wire       w64   = (f3 == 3'b111);
    wire       m_whole = m_unit && rs2f == 5'b01000;     // vl<n>re<eew> / vs<n>r
    wire       m_mask  = m_unit && rs2f == 5'b01011;
    wire       m_ff    = m_unit && rs2f == 5'b10000 && is_ld;
    wire       m_norm  = m_unit && rs2f == 5'b00000;
    wire [3:0] nreg    = {1'b0, nf} + 4'd1;
    wire       nreg_ok = (nf == 3'd0 || nf == 3'd1 || nf == 3'd3 || nf == 3'd7);

    // ---- effective element widths (log2 bytes) and counts ----
    reg  [1:0]  d_eewl;          // vd / vs3 element width
    reg  [1:0]  a_eewl;          // vs2 element width (index width for indexed)
    reg         mask_d;          // vd is addressed as a mask (bit i)
    reg         mask_a;          // vs2 is addressed as a mask (vcpop, vfirst, vm*.mm)
    reg  [31:0] evl;             // elements to process
    reg  signed [4:0] emull;     // log2 EMUL of vd (for alignment checks)
    always @(*) begin
        d_eewl = sewl; a_eewl = sewl; mask_d = 1'b0; mask_a = 1'b0; evl = vl;
        emull = {lmull[3], lmull};
        case (cls)
            C_CMP:   mask_d = 1'b1;
            C_MLOG:  begin mask_d = 1'b1; mask_a = 1'b1; end
            C_CPOP, C_FIRST: mask_a = 1'b1;
            C_MVNR:  begin d_eewl = 2'd2; a_eewl = 2'd2; evl = ({27'd0, rs1f} + 32'd1) << LWPR; emull = 5'sd0; end
            C_LD, C_ST: begin
                if (m_whole)      begin d_eewl = 2'd2; evl = {28'd0, nreg} << LWPR; emull = 5'sd0; end
                else if (m_mask)  begin d_eewl = 2'd0; evl = (vl + 32'd7) >> 3;   emull = 5'sd0; end
                else if (m_idx)   begin d_eewl = sewl; a_eewl = weewl; end
                else begin
                    d_eewl = weewl;
                    emull  = $signed({3'b0, weewl}) - $signed({3'b0, sewl}) + $signed({lmull[3], lmull});
                end
            end
            default: ;
        endcase
    end

    // ---- legality ----
    wire lmul_pos   = ~lmull[3] & (lmull != 0);
    function aligned; input [4:0] r; input signed [4:0] l;
        aligned = (l <= 0) ? 1'b1 : (l == 1) ? ~r[0] : (l == 2) ? (r[1:0] == 0) : (r[2:0] == 0);
    endfunction
    wire uses_vtype = ~(cls == C_MVNR || (cls == C_LD || cls == C_ST) && (m_whole));
    wire reg_ok =
        (cls == C_ARITH || cls == C_SLUP || cls == C_SLDN || cls == C_SL1UP || cls == C_SL1DN) ?
            (aligned(vd, lmull) & aligned(rs2f, lmull) & (~ivv & ~mvv | aligned(rs1f, lmull))) :
        (cls == C_CMP)  ? (aligned(rs2f, lmull) & (~ivv | aligned(rs1f, lmull))) :
        (cls == C_RED)  ? aligned(rs2f, lmull) :
        (cls == C_MVNR) ? (aligned(vd, nrl) & aligned(rs2f, nrl)) :
        (cls == C_LD || cls == C_ST) ? (m_idx ? (aligned(vd, lmull)) : aligned(vd, emull)) : 1'b1;
    // vmv<nr>r: log2 of the register count (simm5 = nr - 1)
    wire signed [4:0] nrl = (rs1f == 5'd7) ? 5'sd3 : (rs1f == 5'd3) ? 5'sd2 : (rs1f == 5'd1) ? 5'sd1 : 5'sd0;
    // masked ops may not write v0 unless their result is a mask
    wire v0_clash = ~vm & (vd == 5'd0) &
                    (cls == C_ARITH || cls == C_SLUP || cls == C_SLDN || cls == C_SL1UP ||
                     cls == C_SL1DN || cls == C_LD || cls == C_VID);
    wire mem_ok = ~mew & ~w64 & (m_strd | m_idx | m_norm | m_ff | m_whole & nreg_ok | m_mask) &
                  (nf == 3'd0 | m_whole) & (~m_mask & ~m_whole | vm) &
                  (emull >= -5'sd3 && emull <= 5'sd3);
    assign illegal = is_vec & (~vs_on |
                     (~is_cfg & (~ok | (uses_vtype & vill) | ~reg_ok | v0_clash |
                                 ((cls == C_LD || cls == C_ST) & ~mem_ok))));
    assign writes_rd = is_cfg | (cls == C_MVXS) | (cls == C_CPOP) | (cls == C_FIRST);

    // =================================================================
    // vsetvl*: the new vtype and vl (the core commits them in EX)
    // =================================================================
    wire        vsetivli = is_cfg && instr[31:30] == 2'b11;
    wire        vsetvl   = is_cfg && instr[31:25] == 7'b1000000;
    wire [31:0] nvt_raw  = vsetvl ? rs2_val : vsetivli ? {22'd0, instr[29:20]} : {21'd0, instr[30:20]};
    wire [2:0]  n_sew = nvt_raw[5:3], n_lmul = nvt_raw[2:0];
    // legal: SEW <= 32, LMUL not reserved, SEW/LMUL <= ELEN, no stray bits
    wire n_frac_ok = ~n_lmul[2] | (n_lmul == 3'b111 && n_sew <= 3'd1) |
                     (n_lmul == 3'b110 && n_sew == 3'd0) ;
    wire n_ok = (n_sew <= 3'd2) && (n_lmul != 3'b100) && n_frac_ok && (nvt_raw[31:8] == 0);
    // VLMAX = VLEN / SEW * LMUL
    wire [31:0] n_vlmax0 = (VLEN >> 3) >> n_sew;
    wire [31:0] n_vlmax  = n_lmul[2] ? (n_vlmax0 >> (4'd8 - {1'b0, n_lmul})) : (n_vlmax0 << n_lmul);
    wire [31:0] avl = vsetivli ? {27'd0, rs1f} :
                      (rs1f != 5'd0) ? rs1_val :
                      (vd != 5'd0)   ? 32'hFFFF_FFFF : vl;
    assign cfg_new_vl = n_ok ? ((avl < n_vlmax) ? avl : n_vlmax) : 32'd0;

    // =================================================================
    // element machinery
    // =================================================================
    localparam S_IDLE=3'd0, S_INIT=3'd1, S_RUN=3'd2, S_FINAL=3'd3, S_DONE=3'd4;
    reg [2:0]  state;
    reg [31:0] idx;                    // current element
    reg [31:0] x1, x2;                 // scalar operands
    reg [31:0] acc;                    // reductions / vcpop / vfirst
    reg        found;
    reg [VLEN-1:0] mres, mwr;          // mask results, and which bits were written
    reg [31:0] eaddr;                  // strided: running element address
    reg [LWPR:0] fw;                   // FINAL: mask word being written
    assign busy = (state != S_IDLE);

    // ---- VRF addressing: element i of the group starting at register r ----
    function [AW-1:0] ewa; input [4:0] r; input [31:0] i; input [1:0] el;
        reg [31:0] byteoff;
        begin byteoff = i << el; ewa = ({r, {LWPR{1'b0}}}) + byteoff[AW+1:2]; end
    endfunction
    function [AW-1:0] mwa; input [4:0] r; input [31:0] i;      // mask bit i
        mwa = ({r, {LWPR{1'b0}}}) + i[AW+4:5];
    endfunction
    // read element at lane from a word, zero-extended
    function [31:0] getz; input [31:0] w; input [1:0] lane; input [1:0] el;
        reg [31:0] s;
        begin s = w >> {lane, 3'b000};
            getz = (el == 2'd0) ? {24'd0, s[7:0]} : (el == 2'd1) ? {16'd0, s[15:0]} : s;
        end
    endfunction
    function [31:0] sext; input [31:0] v; input [1:0] el;
        sext = (el == 2'd0) ? {{24{v[7]}}, v[7:0]} : (el == 2'd1) ? {{16{v[15]}}, v[15:0]} : v;
    endfunction
    function [31:0] zext; input [31:0] v; input [1:0] el;
        zext = (el == 2'd0) ? {24'd0, v[7:0]} : (el == 2'd1) ? {16'd0, v[15:0]} : v;
    endfunction
    // put element v into word w at lane
    function [31:0] put; input [31:0] w; input [31:0] v; input [1:0] lane; input [1:0] el;
        reg [31:0] m;
        begin
            m = ((el == 2'd0) ? 32'h0000_00FF : (el == 2'd1) ? 32'h0000_FFFF : 32'hFFFF_FFFF) << {lane, 3'b000};
            put = (w & ~m) | ((v << {lane, 3'b000}) & m);
        end
    endfunction

    // ---- latched instruction fields (stable while busy: EX holds it) ----
    wire [31:0] vlmax_cur = ((VLEN >> 3) >> sewl) << (lmull[3] ? 0 : lmull);
    wire [31:0] vlmax_now = lmull[3] ? (((VLEN >> 3) >> sewl) >> (-lmull)) : vlmax_cur;

    // source element index for vs2 (slides move it)
    reg  [31:0] sidx; reg sidx_ok;
    always @(*) begin
        sidx = idx; sidx_ok = 1'b1;
        case (cls)
            C_SLUP:  begin sidx = idx - x1; end
            C_SL1UP: begin sidx = idx - 32'd1; sidx_ok = (idx != 0); end
            C_SLDN:  begin sidx = idx + x1; sidx_ok = (idx + x1 < vlmax_now) && (idx + x1 >= idx); end
            C_SL1DN: begin sidx = idx + 32'd1; sidx_ok = (idx + 32'd1 < vl); end
            C_RED, C_MVXS: if (state == S_INIT) sidx = 32'd0;
            default: ;
        endcase
    end

    // ---- VRF reads ----
    wire [31:0] i_d = (cls == C_MVSX) ? 32'd0 : idx;
    wire [AW-1:0] a_addr = mask_a ? mwa(rs2f, idx) : ewa(rs2f, sidx, a_eewl);
    wire [AW-1:0] b_addr = mask_a ? mwa(rs1f, idx) : ewa(rs1f, (cls == C_RED) ? 32'd0 : idx, sewl);
    wire [AW-1:0] c_addr = (state == S_FINAL) ? ({vd, {LWPR{1'b0}}} + fw[LWPR-1:0]) :
                           mask_d ? mwa(vd, idx) : ewa(vd, i_d, d_eewl);
    wire [AW-1:0] m_addr = mwa(5'd0, idx);
    wire [31:0] wa = vrf[a_addr], wb = vrf[b_addr], wc = vrf[c_addr], wm = vrf[m_addr];
    wire [31:0] wnr = vrf[ewa(rs2f, idx, 2'd2)];             // vmv<nr>r source word

    wire [31:0] a_boff = sidx << a_eewl, d_boff = i_d << d_eewl;
    wire [31:0] e2  = mask_a ? {31'd0, wa[idx[4:0]]} : getz(wa, a_boff[1:0], a_eewl); // vs2[i]
    wire [31:0] e1v = getz(wb, idx[1:0] << sewl, sewl);                                 // vs1[i]
    wire [31:0] e1m = {31'd0, wb[idx[4:0]]};
    wire [31:0] e1r = getz(wb, 2'd0, sewl);                                              // vs1[0]
    wire [31:0] ed  = getz(wc, d_boff[1:0], d_eewl);                                     // vd[i]
    wire        v0i = wm[idx[4:0]];
    wire [31:0] e1  = ivv | mvv ? e1v :
                      ivi ? (((f6 == 6'b100101) || (f6 == 6'b101000) || (f6 == 6'b101001) ||
                              (f6 == 6'b001110) || (f6 == 6'b001111)) ? {27'd0, rs1f}
                                                                     : {{27{rs1f[4]}}, rs1f}) : x1;

    // ---- element ALU ----
    wire [31:0] s2 = sext(e2, sewl), z2 = zext(e2, sewl), s1 = sext(e1, sewl), z1 = zext(e1, sewl);
    wire [31:0] sd = sext(ed, sewl), zd = zext(ed, sewl);
    wire [4:0]  shm = (sewl == 2'd0) ? {2'b0, e1[2:0]} : (sewl == 2'd1) ? {1'b0, e1[3:0]} : e1[4:0];
    // multiplier operands (vmadd / vnmsub multiply vd instead of vs2)
    wire        mul_vd = (f6 == 6'b101001) || (f6 == 6'b101011);
    wire [31:0] mA = mul_vd ? ed : e2;
    wire [31:0] mAz = zext(mA, sewl), mAx = sext(mA, sewl);
    wire signed [32:0] mAs = (f6 == 6'b100100) ? $signed({1'b0, mAz}) : $signed({mAx[31], mAx});
    wire signed [32:0] mBs = (f6 == 6'b100100 || f6 == 6'b100110) ? $signed({1'b0, z1}) : $signed({s1[31], s1});
    wire signed [65:0] prod = mAs * mBs;
    wire [31:0] p_lo = prod[31:0];
    wire [31:0] p_hi = (sewl == 2'd0) ? prod[15:8] : (sewl == 2'd1) ? prod[31:16] : prod[63:32];

    reg [31:0] r;                       // element result (vd)
    always @(*) begin
        r = 32'd0;
        if (iv) case (f6)
            6'b000000: r = e2 + e1;
            6'b000010: r = e2 - e1;
            6'b000011: r = e1 - e2;
            6'b000100: r = (z2 < z1) ? e2 : e1;
            6'b000101: r = ($signed(s2) < $signed(s1)) ? e2 : e1;
            6'b000110: r = (z2 < z1) ? e1 : e2;
            6'b000111: r = ($signed(s2) < $signed(s1)) ? e1 : e2;
            6'b001001: r = e2 & e1;
            6'b001010: r = e2 | e1;
            6'b001011: r = e2 ^ e1;
            6'b100101: r = z2 << shm;
            6'b101000: r = z2 >> shm;
            6'b101001: r = $signed(s2) >>> shm;
            6'b010111: r = (vm | v0i) ? e1 : e2;                 // vmv / vmerge
            default:   r = e2;                                   // slides: vs2[src]
        endcase
        else case (f6)                                            // OPMVV / OPMVX
            6'b100101: r = p_lo;                                  // vmul
            6'b100100, 6'b100110, 6'b100111: r = p_hi;            // vmulhu / vmulhsu / vmulh
            6'b101101: r = p_lo + ed;                             // vmacc
            6'b101111: r = ed - p_lo;                             // vnmsac
            6'b101001: r = p_lo + e2;                             // vmadd
            6'b101011: r = e2 - p_lo;                             // vnmsub
            default:   r = e2;                                    // slide1: vs2[src]
        endcase
    end

    // compares
    reg cmp;
    always @(*) case (f6)
        6'b011000: cmp = (z2 == z1);
        6'b011001: cmp = (z2 != z1);
        6'b011010: cmp = (z2 <  z1);
        6'b011011: cmp = ($signed(s2) <  $signed(s1));
        6'b011100: cmp = (z2 <= z1);
        6'b011101: cmp = ($signed(s2) <= $signed(s1));
        6'b011110: cmp = (z2 >  z1);
        default:   cmp = ($signed(s2) >  $signed(s1));
    endcase
    // mask logical (vs2 op vs1, bitwise on mask bits)
    reg mlog;
    always @(*) case (f6[2:0])
        3'b000: mlog =  e2[0] & ~e1m[0];      // vmandn
        3'b001: mlog =  e2[0] &  e1m[0];      // vmand
        3'b010: mlog =  e2[0] |  e1m[0];      // vmor
        3'b011: mlog =  e2[0] ^  e1m[0];      // vmxor
        3'b100: mlog =  e2[0] | ~e1m[0];      // vmorn
        3'b101: mlog = ~(e2[0] & e1m[0]);     // vmnand
        3'b110: mlog = ~(e2[0] | e1m[0]);     // vmnor
        default: mlog = ~(e2[0] ^ e1m[0]);    // vmxnor
    endcase
    // reductions (acc op vs2[i])
    reg [31:0] red;
    wire [31:0] sa = sext(acc, sewl), za = zext(acc, sewl);
    always @(*) case (f6[2:0])
        3'b000: red = acc + e2;
        3'b001: red = acc & e2;
        3'b010: red = acc | e2;
        3'b011: red = acc ^ e2;
        3'b100: red = (z2 < za) ? e2 : acc;
        3'b101: red = ($signed(s2) < $signed(sa)) ? e2 : acc;
        3'b110: red = (z2 > za) ? e2 : acc;
        default: red = ($signed(s2) > $signed(sa)) ? e2 : acc;
    endcase

    // ---- which elements are active ----
    wire last    = (idx + 32'd1 >= evl);
    wire masked  = ~vm & ~v0i & ~(iv && f6 == 6'b010111);      // vmerge uses v0 as data
    wire unmask  = (cls == C_MLOG) | (cls == C_MVNR) | ((cls == C_LD || cls == C_ST) & (m_whole | m_mask));
    wire active  = ~(masked & ~unmask) & ~((cls == C_SLUP) && (idx < x1));

    // ---- memory ----
    assign mem_active = busy & (cls == C_LD || cls == C_ST);
    wire [31:0] el_bytes = 32'd1 << d_eewl;
    assign mem_va = m_idx ? (x1 + zext(e2, a_eewl)) :
                    m_strd ? eaddr :
                    (x1 + (idx << d_eewl));
    assign mem_store = (cls == C_ST);
    wire   mem_el    = (state == S_RUN) & mem_active & (idx < evl) & active;
    assign mem_want  = mem_el;
    assign mem_req   = mem_el & xl_ok & ~xl_fault;
    wire [1:0] lane  = mem_va[1:0];
    assign mem_be    = ((d_eewl == 2'd0) ? 4'b0001 : (d_eewl == 2'd1) ? 4'b0011 : 4'b1111) << lane;
    assign mem_wdata = ed << {lane, 3'b000};
    wire [31:0] ld_el = getz(mem_rdata, lane, d_eewl);

    // ---- VRF write port ----
    // w_addr depends on the state alone, never on an element's mask bit or
    // data (`we` gates the write): in LUT RAM the write address also drives
    // a read port, so a data-dependent w_addr would be a combinational loop.
    reg          we;
    wire [AW-1:0] w_addr = (cls == C_MVNR && state == S_RUN) ? ewa(vd, idx, 2'd2) : c_addr;
    reg [31:0]   w_data;
    always @(*) begin
        we = 1'b0; w_data = wc;
        if (state == S_RUN && idx < evl && active) case (cls)
            C_ARITH, C_SLDN, C_SL1DN, C_SLUP, C_SL1UP: begin
                we = sidx_ok | (cls == C_SLDN);
                w_data = put(wc, (cls == C_SL1UP && idx == 0) ? x1 :
                                 (cls == C_SL1DN && last)     ? x1 :
                                 (cls == C_SLDN && !sidx_ok)  ? 32'd0 : r, d_boff[1:0], d_eewl);
                if ((cls == C_SL1UP && idx == 0) || (cls == C_SL1DN && last)) we = 1'b1;
            end
            C_VID:  begin we = 1'b1; w_data = put(wc, idx, d_boff[1:0], d_eewl); end
            C_MVNR: begin we = 1'b1; w_data = wnr; end
            C_LD:   if (mem_done) begin we = 1'b1; w_data = put(wc, ld_el, d_boff[1:0], d_eewl); end
            default: ;
        endcase
        else if (state == S_INIT && cls == C_MVSX && vl != 0 && vstart < vl) begin
            we = 1'b1; w_data = put(wc, x1, 2'd0, sewl);
        end else if (state == S_FINAL && cls == C_RED) begin
            we = 1'b1; w_data = put(wc, acc, 2'd0, sewl);         // c_addr = vd word 0 here
        end else if (state == S_FINAL && (cls == C_CMP || cls == C_MLOG)) begin
            we = 1'b1;
            w_data = (wc & ~mwr[32*fw[LWPR-1:0] +: 32]) | (mres[32*fw[LWPR-1:0] +: 32] & mwr[32*fw[LWPR-1:0] +: 32]);
        end
    end
    always @(posedge clk) if (we) vrf[w_addr] <= w_data;

    // =================================================================
    // sequencer
    // =================================================================
    wire empty = (vstart >= evl);
    // any change to vector state marks mstatus.VS Dirty
    assign vs_dirty = done | cfg_commit | csr_we;

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            state <= S_IDLE; vl <= 0; vtype <= 32'h8000_0000; vstart <= 0; vxrm <= 0; vxsat <= 0;
            fault <= 1'b0;
        end else begin
            if (cfg_commit) begin
                vtype <= n_ok ? {24'd0, nvt_raw[7:0]} : 32'h8000_0000;
                vl    <= cfg_new_vl;
                vstart <= 0;
            end
            if (csr_we) case (csr_addr)
                12'h008: vstart <= csr_wdata & (VLEN - 1);
                12'h009: vxsat  <= csr_wdata[0];
                12'h00A: vxrm   <= csr_wdata[1:0];
                12'h00F: begin vxsat <= csr_wdata[0]; vxrm <= csr_wdata[2:1]; end
                default: ;
            endcase
            case (state)
                S_IDLE: if (start) begin
                    x1 <= ivi ? {27'd0, rs1f} : rs1_val;   // vslide*.vi: the offset is uimm5
                    x2 <= rs2_val; idx <= vstart;
                    fault <= 1'b0; found <= 1'b0; mwr <= {VLEN{1'b0}};
                    acc <= (cls == C_FIRST) ? 32'hFFFF_FFFF : 32'd0;
                    eaddr <= rs1_val + vstart * rs2_val;
                    state <= S_INIT;
                end
                S_INIT: begin
                    if (cls == C_RED) acc <= e1r;
                    if (cls == C_MVXS) begin scalar_out <= sext(e2, sewl); state <= S_DONE; end
                    else if (cls == C_MVSX) state <= S_DONE;
                    else if (empty) state <= S_DONE;          // vl = 0 or vstart >= vl
                    else state <= S_RUN;
                    fw <= 0;
                end
                S_RUN: begin
                    // memory elements wait for their access; a fault ends it
                    if (mem_el & xl_fault) begin
                        if (m_ff && idx != 0) begin vl <= idx; state <= S_DONE; end
                        else begin
                            fault <= 1'b1; fault_cause <= mem_store ? 4'd15 : 4'd13;
                            fault_tval <= mem_va; vstart <= idx; state <= S_DONE;
                        end
                    end else if (~mem_el | mem_done) begin
                        if (idx < evl && active) case (cls)
                            C_CMP:  begin mres[idx[$clog2(VLEN)-1:0]] <= cmp;  mwr[idx[$clog2(VLEN)-1:0]] <= 1'b1; end
                            C_MLOG: begin mres[idx[$clog2(VLEN)-1:0]] <= mlog; mwr[idx[$clog2(VLEN)-1:0]] <= 1'b1; end
                            C_RED:  acc <= red;
                            C_CPOP: acc <= acc + e2[0];
                            C_FIRST: if (e2[0] && !found) begin acc <= idx; found <= 1'b1; end
                            default: ;
                        endcase
                        if (m_strd) eaddr <= eaddr + x2;
                        idx <= idx + 32'd1;
                        if (last) state <= (cls == C_RED || cls == C_CMP || cls == C_MLOG) ? S_FINAL : S_DONE;
                    end
                end
                S_FINAL: begin
                    if (cls == C_RED) state <= S_DONE;
                    else begin
                        fw <= fw + 1'b1;
                        if (fw == WPR - 1) state <= S_DONE;
                    end
                end
                S_DONE: begin
                    if (!fault) vstart <= 0;
                    if (cls == C_CPOP || cls == C_FIRST) scalar_out <= acc;
                    done <= 1'b1;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // =================================================================
    // CSRs
    // =================================================================
    always @(*) begin
        csr_hit = 1'b1;
        case (csr_addr)
            12'h008: csr_rdata = vstart;
            12'h009: csr_rdata = {31'd0, vxsat};
            12'h00A: csr_rdata = {30'd0, vxrm};
            12'h00F: csr_rdata = {29'd0, vxrm, vxsat};
            12'hC20: csr_rdata = vl;
            12'hC21: csr_rdata = vtype;
            12'hC22: csr_rdata = VLEN / 8;
            default: begin csr_hit = 1'b0; csr_rdata = 32'd0; end
        endcase
    end
endmodule

`default_nettype wire
