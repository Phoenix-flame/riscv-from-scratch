// =====================================================================
// mmu.v  -  RISC-V Sv32 address translation (data side)
// ---------------------------------------------------------------------
// Translates a 32-bit virtual address to a physical address using a
// two-level page table, exactly as RISC-V Sv32 specifies:
//
//   VA = | VPN[1] (10) | VPN[0] (10) | offset (12) |
//   satp = | MODE(1) | ASID(9) | PPN(22) |     MODE=1 => Sv32 on
//
//   walk:  pte1 = mem[satp.ppn*4096 + VPN1*4]
//          if pte1 is a leaf (R or X set) -> 4 MiB superpage
//          else                            -> pte0 = mem[pte1.ppn*4096 + VPN0*4]
//                                             4 KiB page
//
// Translation is active only in USER mode with Sv32 enabled; machine
// mode always uses physical addresses directly. PTE reads come from two
// dedicated combinational RAM read ports (so the whole walk completes in
// one cycle -- idealized; real hardware walks over several cycles and
// caches results in a TLB).
//
// PTE bits:  V=0 R=1 W=2 X=3 U=4 G=5 A=6 D=7 ; PPN = pte[31:10]
//            (superpage PPN[1] = pte[31:20])
// =====================================================================
`default_nettype none

module mmu (
    input  wire [31:0] satp,
    input  wire [1:0]  priv,        // 2'b00 = U, 2'b11 = M
    input  wire [31:0] va,          // virtual address from the datapath
    input  wire        is_load,
    input  wire        is_store,
    input  wire        req,         // a data access is happening this cycle

    output wire [31:0] walk_addr1,  // -> RAM walk port 1 (level-1 PTE)
    input  wire [31:0] walk_data1,
    output wire [31:0] walk_addr2,  // -> RAM walk port 2 (level-0 PTE)
    input  wire [31:0] walk_data2,

    output wire [31:0] pa,          // translated physical address
    output wire        active,      // translation is on for this access
    output wire        fault,       // page fault (raise exception)
    output wire        fault_store  // distinguishes store(15) vs load(13)
);
    wire sv32 = satp[31];
    assign active = (priv == 2'b00) && sv32;     // user mode + Sv32

    wire [21:0] root_ppn = satp[21:0];
    wire [9:0]  vpn1 = va[31:22];
    wire [9:0]  vpn0 = va[21:12];
    wire [11:0] off  = va[11:0];

    // ---- level 1 ----
    assign walk_addr1 = {root_ppn, 12'b0} + {20'b0, vpn1, 2'b0};
    wire [31:0] pte1 = walk_data1;
    wire pte1_v = pte1[0], pte1_r = pte1[1], pte1_w = pte1[2], pte1_x = pte1[3], pte1_u = pte1[4];
    wire pte1_leaf = pte1_r | pte1_x;            // a leaf maps a superpage
    wire pte1_bad  = ~pte1_v | (~pte1_r & pte1_w);

    // ---- level 0 (only meaningful when pte1 is a pointer) ----
    wire [21:0] pte1_ppn = pte1[31:10];
    assign walk_addr2 = {pte1_ppn, 12'b0} + {20'b0, vpn0, 2'b0};
    wire [31:0] pte0 = walk_data2;
    wire pte0_v = pte0[0], pte0_r = pte0[1], pte0_w = pte0[2], pte0_x = pte0[3], pte0_u = pte0[4];
    wire pte0_leaf = pte0_r | pte0_x;
    wire pte0_bad  = ~pte0_v | (~pte0_r & pte0_w);

    // ---- pick the leaf and form the physical address ----
    wire use_super = pte1_leaf;
    wire        leaf_u = use_super ? pte1_u : pte0_u;
    wire        leaf_r = use_super ? pte1_r : pte0_r;
    wire        leaf_w = use_super ? pte1_w : pte0_w;
    wire [31:0] pa_super = {pte1[31:20], va[21:0]};   // 4 MiB superpage
    wire [31:0] pa_4k    = {pte0[31:10], off};        // 4 KiB page
    wire [31:0] pa_xlat  = use_super ? pa_super : pa_4k;

    // ---- faults ----
    wire walk_fault = pte1_bad           ? 1'b1 :   // bad level-1 PTE
                      pte1_leaf          ? 1'b0 :   // superpage: stop here
                      pte0_bad           ? 1'b1 :   // bad level-0 PTE
                      ~pte0_leaf         ? 1'b1 :   // level-0 must be a leaf
                                           1'b0;
    wire perm_fault = ~walk_fault & ( ~leaf_u            |   // U-mode needs U=1
                                      (is_load  & ~leaf_r) |
                                      (is_store & ~leaf_w) );

    assign fault       = active & req & (walk_fault | perm_fault);
    assign fault_store = is_store;
    assign pa          = active ? pa_xlat : va;       // identity when inactive
endmodule

`default_nettype wire
