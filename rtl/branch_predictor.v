// =====================================================================
// branch_predictor.v  -  BTB + 2-bit saturating-counter direction predictor
// ---------------------------------------------------------------------
// Two tables, both indexed by the low PC bits (word-aligned):
//
//   * BHT (branch history table): one 2-bit saturating counter per index.
//       00,01 = predict NOT taken   10,11 = predict TAKEN
//     The counter needs two wrong guesses in a row to flip its prediction,
//     so a loop branch that is taken N times then falls through once is
//     mispredicted only on that last iteration (not on re-entry).
//
//   * BTB (branch target buffer): a small tagged cache of {tag, target}.
//     A *taken* control transfer records where it went, so the next time we
//     fetch that PC we can redirect immediately -- before the instruction is
//     even decoded. Without a target there is nothing to predict, so a
//     prediction is "taken" only on a BTB hit whose counter is in a taken state.
//
// PREDICT is purely combinational on the IF-stage PC (it runs in parallel
// with the instruction fetch). UPDATE is synchronous and happens when a
// control instruction resolves in EX, with its true direction and target.
//
// Unconditional jumps (jal/jalr) are forced to strong-taken so they are
// predicted taken from the second time they are seen.
// =====================================================================
`default_nettype none

module branch_predictor #(
    parameter IDX_BITS = 6                       // 2**IDX_BITS entries per table
) (
    input  wire        clk,
    input  wire        rst,

    // ---- predict (combinational), for the instruction being fetched ----
    input  wire [31:0] pc_if,
    output wire        predict_taken,
    output wire [31:0] predict_target,

    // ---- update (synchronous), when a control instr resolves in EX ----
    input  wire        upd_en,                   // a branch/jump retired in EX
    input  wire [31:0] upd_pc,                   // its PC
    input  wire        upd_taken,                // its true direction
    input  wire        upd_is_jump,              // unconditional (jal/jalr)?
    input  wire [31:0] upd_target                // its true target (if taken)
);
    localparam N    = (1 << IDX_BITS);
    localparam TAGW = 32 - (IDX_BITS + 2);

    reg [1:0]      bht       [0:N-1];
    reg            btb_valid [0:N-1];
    reg [TAGW-1:0] btb_tag   [0:N-1];
    reg [31:0]     btb_target[0:N-1];

    // ---- index / tag slices ----
    wire [IDX_BITS-1:0] if_idx = pc_if [IDX_BITS+1:2];
    wire [TAGW-1:0]     if_tag = pc_if [31:IDX_BITS+2];
    wire [IDX_BITS-1:0] up_idx = upd_pc[IDX_BITS+1:2];
    wire [TAGW-1:0]     up_tag = upd_pc[31:IDX_BITS+2];

    // ---- prediction ----
    wire btb_hit = btb_valid[if_idx] && (btb_tag[if_idx] == if_tag);
    assign predict_taken  = btb_hit && bht[if_idx][1];   // hit AND counter says taken
    assign predict_target = btb_target[if_idx];

    // ---- update ----
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < N; i = i + 1) begin
                bht[i]       <= 2'b01;            // weakly not-taken
                btb_valid[i] <= 1'b0;
                btb_tag[i]   <= {TAGW{1'b0}};
                btb_target[i]<= 32'd0;
            end
        end else if (upd_en) begin
            // 2-bit saturating direction counter
            if (upd_is_jump)
                bht[up_idx] <= 2'b11;                              // jumps: always taken
            else if (upd_taken)
                bht[up_idx] <= (bht[up_idx]==2'b11) ? 2'b11 : bht[up_idx] + 2'b01;
            else
                bht[up_idx] <= (bht[up_idx]==2'b00) ? 2'b00 : bht[up_idx] - 2'b01;
            // allocate / refresh the BTB only when the branch was taken
            if (upd_taken) begin
                btb_valid[up_idx]  <= 1'b1;
                btb_tag[up_idx]    <= up_tag;
                btb_target[up_idx] <= upd_target;
            end
        end
    end
endmodule

`default_nettype wire
