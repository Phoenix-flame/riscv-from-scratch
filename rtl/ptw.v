// =====================================================================
// ptw.v  -  Sv32 page-table walker on a stall-capable memory port
// ---------------------------------------------------------------------
// The pipelined core (cpu_pipe_u) cannot sequence a walk through its own
// FSM the way the multi-cycle cores do, so the walk lives here, in a
// small engine that borrows the core's data port:
//
//   IDLE --start--> L1 : read the level-1 PTE   (satp.ppn*4096 + VPN1*4)
//                         leaf    -> done (4 MiB superpage)
//                         pointer -> L0
//                         bad     -> done (fault)
//                   L0 : read the level-0 PTE   (pte1.ppn*4096 + VPN0*4)
//                         leaf    -> done (4 KiB page)
//                         else    -> done (fault)
//
// Each read is one request on the port, held until `ready` (a cache hit
// answers the same cycle; a miss answers whenever the refill finishes).
// On a good leaf the walker emits a one-cycle `fill` for the requesting
// side's TLB; on a bad PTE, a one-cycle `fault`. Permission bits are not
// checked here -- the leaf goes into the TLB and the core checks it.
//
// `kill` abandons the *result* of a fetch-side walk (its instruction was
// flushed). The walk still runs to the end of its current read so the
// port is never dropped in the middle of a transfer. LATE_KILL=1 (Step 58)
// lets a fill that completes in the very cycle of the kill through -- a
// valid translation, which a TLB may always cache -- so the pipeline's
// flush is not in front of every TLB entry's enable; a fault is still
// dropped at once.
//
// Step 50. SVADE=1 makes the walker honour the A and D bits the way the
// Svade extension says -- by faulting, not by updating them: a leaf with
// A=0 is no translation at all (a page fault, so the kernel can set A and
// retry), and a leaf with D=0 goes into the TLB without W, so the first
// store to the page takes a store page fault. SVADE=0 ignores them, as
// every walker in this project did before (and as the older MMU programs,
// whose PTEs leave A and D clear, still expect).
// `mem_ok` says the PTE's address is readable memory (the core's PMA
// check); if it is not, the walk ends without touching the port and
// reports `done_af` -- an ACCESS fault for the access that needed it.
// =====================================================================
`default_nettype none

module ptw #(
    parameter SVADE      = 0,
    parameter LATE_KILL  = 0,
    parameter REG_RESULT = 0      // 1: the result one cycle late, from registers (Step 58)
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] satp,

    // ---- requests (sampled only in IDLE; data side has priority) ----
    input  wire        start_d,
    input  wire [31:0] va_d,
    input  wire        start_i,
    input  wire [31:0] va_i,
    input  wire        kill,          // drop an in-flight fetch-side walk

    // ---- memory port (owned whenever busy) ----
    output wire        busy,
    output wire        mem_req,       // a read is wanted now (busy, but not in S_DONE)
    output reg  [31:0] mem_addr,
    input  wire [31:0] mem_rdata,
    input  wire        mem_ready,
    input  wire        mem_ok,        // mem_addr is readable (PMA)

    // ---- result (one-cycle pulses) ----
    output wire        done_fill,     // a valid leaf: fill side's TLB
    output wire        done_fault,    // a bad PTE: no translation exists
    output wire        done_af,       // ... because a PTE could not be read (with done_fault)
    output reg         side_i,        // 1 = fetch-side walk, 0 = data-side
    output reg  [31:0] va,            // the VA being walked
    output wire [21:0] leaf_ppn,      // pte[31:10]
    output wire        leaf_super,
    output wire [3:0]  leaf_perm      // {U, X, W, R}
);
    localparam S_IDLE=2'd0, S_L1=2'd1, S_L0=2'd2, S_DONE=2'd3;
    reg [1:0]  state;
    reg [21:0] l0_ppn;               // level-1 pointer -> level-0 table
    reg        killed;

    assign busy = (state != S_IDLE);
    wire   walking = (state == S_L1) | (state == S_L0);
    assign mem_req = walking;

    always @(*) begin
        case (state)
            S_L1:    mem_addr = {satp[21:0], 12'b0} + {20'b0, va[31:22], 2'b0};
            S_L0:    mem_addr = {l0_ppn, 12'b0}     + {20'b0, va[21:12], 2'b0};
            default: mem_addr = 32'd0;
        endcase
    end

    wire [31:0] pte  = mem_rdata;
    wire pte_v = pte[0], pte_r = pte[1], pte_w = pte[2], pte_x = pte[3];
    wire pte_a = pte[6], pte_d = pte[7];
    wire pte_leaf = pte_r | pte_x;
    wire pte_bad  = ~pte_v | (~pte_r & pte_w) | ((SVADE != 0) & pte_leaf & ~pte_a);

    // an unreadable PTE address ends the walk at once, without a request
    wire noread = walking & ~mem_ok;
    wire at_l1 = (state == S_L1) & (mem_ready | noread);
    wire at_l0 = (state == S_L0) & (mem_ready | noread);
    wire good  = ~noread & ((at_l1 & ~pte_bad & pte_leaf) | (at_l0 & ~pte_bad & pte_leaf));
    wire bad   = noread | (at_l1 & pte_bad) | (at_l0 & (pte_bad | ~pte_leaf));
    wire drop  = killed | (kill & side_i);

    // REG_RESULT: the outcome and the PTE are registered when the read
    // answers, and reported from S_DONE the cycle after -- so the D-port's
    // answer (a cache hit, the address decode) is not in front of every TLB
    // entry's write enable. The port stays the walker's, with no request.
    reg        r_good, r_bad, r_af, r_super;
    reg [31:0] r_pte;
    wire       done_now = (state == S_DONE);
    wire       out_good = REG_RESULT ? done_now & r_good : good;
    wire       out_bad  = REG_RESULT ? done_now & r_bad  : bad;
    wire       out_af   = REG_RESULT ? done_now & r_af   : noread;
    wire [31:0] out_pte = REG_RESULT ? r_pte : pte;

    assign done_fill  = out_good & ~(LATE_KILL ? killed : drop);
    assign done_fault = out_bad  & ~drop;
    assign done_af    = out_af   & ~drop;
    assign leaf_ppn   = out_pte[31:10];
    assign leaf_super = REG_RESULT ? r_super : (state == S_L1);
    // Svade: no W until D is set, so the first store faults
    assign leaf_perm  = {out_pte[4], out_pte[3], out_pte[2] & (out_pte[7] | (SVADE == 0)), out_pte[1]};

    always @(posedge clk)
        if (walking && (noread || mem_ready)) begin
            r_good <= good; r_bad <= bad; r_af <= noread; r_pte <= pte; r_super <= (state == S_L1);
        end

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; side_i <= 1'b0; va <= 32'd0; l0_ppn <= 22'd0; killed <= 1'b0;
        end else begin
            if (kill & side_i & busy) killed <= 1'b1;
            case (state)
                S_IDLE: begin
                    killed <= 1'b0;
                    if (start_d)      begin side_i <= 1'b0; va <= va_d; state <= S_L1; end
                    else if (start_i) begin side_i <= 1'b1; va <= va_i; state <= S_L1; end
                end
                S_L1: if (noread) state <= REG_RESULT ? S_DONE : S_IDLE;
                      else if (mem_ready) begin
                          if (pte_bad | pte_leaf) state <= REG_RESULT ? S_DONE : S_IDLE;
                          else begin l0_ppn <= pte[31:10]; state <= S_L0; end
                      end
                S_L0: if (noread | mem_ready) state <= REG_RESULT ? S_DONE : S_IDLE;
                default: state <= S_IDLE;            // S_DONE: the result was reported
            endcase
        end
    end
endmodule

`default_nettype wire
