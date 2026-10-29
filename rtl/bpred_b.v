// =====================================================================
// bpred_b.v  -  BTB + 2-bit counters in one block RAM, read a cycle ahead
// ---------------------------------------------------------------------
// Step 60. branch_predictor.v reads its tables combinationally on the IF
// PC and resets every entry, so it is flip-flops and LUT RAM, and its
// lookup sits on the path into the next PC. This one keeps each entry,
// {tag, counter, target}, in block RAM, and reads it at the edge BEFORE the
// fetch: at the PC register's next value (`rd_pc`, the core's pc_d). In the
// cycle that PC is fetched the entry is already in the RAM's output
// register, and the prediction is a tag compare against the PC.
//
// Nothing here is ever required to be right: the core checks every
// prediction in EX. So there is no valid bit and no reset clear. An entry
// that does not belong to the PC (left over from another program, or
// read during its own update) only costs a misprediction. The RAM starts
// at 0 (the bitstream's initial contents), and counter 0 predicts nothing.
//
// The counter is not read again to update it: the prediction's own
// {hit, counter} rides down the pipe with the instruction (`info`), and
// EX hands it back. Update, for a branch or jump leaving EX:
//   * jal / jalr                 {tag, 11, target}
//   * a branch that hit          {tag, counter +/- 1, target}
//   * a taken branch that missed {tag, 10, target} (allocate, weakly taken)
//   * a not-taken one that missed  nothing
// =====================================================================
`default_nettype none

module bpred_b #(
    parameter IDX_BITS = 9,                      // 512 entries: one RAMB36 (512 x 72)
    parameter TAGW     = 32 - IDX_BITS - 2       // a shorter tag only aliases more often
) (
    input  wire        clk,
    input  wire        rst,

    // ---- predict ----
    input  wire [31:0] rd_pc,                    // the PC fetched next cycle
    input  wire [31:0] pc,                       // the PC fetched now (last cycle's rd_pc)
    output wire        taken,
    output wire [31:0] target,
    output wire [2:0]  info,                     // {hit, counter}: ride down to EX

    // ---- update (a control instruction leaving EX) ----
    input  wire        upd_en,
    input  wire [31:0] upd_pc,
    input  wire        upd_taken,
    input  wire        upd_is_jump,
    input  wire [31:0] upd_target,
    input  wire [2:0]  upd_info                  // the info this instruction was predicted with
);
    localparam N  = 1 << IDX_BITS;
    localparam EW = TAGW + 2 + 30;               // {tag, counter, target[31:2]}

    reg [EW-1:0] tab [0:N-1];
    integer i;
    initial for (i = 0; i < N; i = i + 1) tab[i] = {EW{1'b0}};

    reg [EW-1:0] ent_q;
    wire [TAGW-1:0] e_tag = ent_q[EW-1 -: TAGW];
    wire [1:0]      e_ctr = ent_q[31:30];
    wire            hit   = (e_tag == pc[IDX_BITS+2 +: TAGW]);
    assign taken  = hit & e_ctr[1];
    assign target = {ent_q[29:0], 2'b00};
    assign info   = {hit, e_ctr};

    wire       u_hit = upd_info[2];
    wire [1:0] u_ctr = upd_info[1:0];
    wire [1:0] n_ctr = upd_is_jump ? 2'b11 :
                       ~u_hit      ? 2'b10 :
                       upd_taken   ? ((u_ctr == 2'b11) ? 2'b11 : u_ctr + 2'b01) :
                                     ((u_ctr == 2'b00) ? 2'b00 : u_ctr - 2'b01);
    wire       we    = upd_en & (upd_is_jump | u_hit | upd_taken);
    wire [IDX_BITS-1:0] widx = upd_pc[IDX_BITS+1:2];

    always @(posedge clk) begin
        if (we) tab[widx] <= {upd_pc[IDX_BITS+2 +: TAGW], n_ctr, upd_target[31:2]};
        ent_q <= tab[rd_pc[IDX_BITS+1:2]];
    end
endmodule

`default_nettype wire
