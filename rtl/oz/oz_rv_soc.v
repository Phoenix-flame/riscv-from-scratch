// =====================================================================
// oz_rv_soc.v  -  the configurable RISC-V SoC for OpenZynq (Step 45)
// ---------------------------------------------------------------------
// One SoC, every core in the project behind the same memory map. The
// generator (tools/rvgen, driven by `make menuconfig`) sets these
// parameters from a Kconfig .config; nothing here is board-specific --
// the generated top level adds clocks, reset, pins and (in PS-attached
// builds) the AXI host bridge.
//
//   CORE = 0  cpu_pipe_u   5-stage pipeline: M/A/Zb*/U/S/MMU/predictor are
//                          individually switchable; memory through the
//                          I/D caches (CACHES=1) or uncached bridges
//   CORE = 1  cpu_mc       multi-cycle RV32IM
//   CORE = 2  cpu_mc_c     multi-cycle RV32IMC
//   CORE = 3  cpu_mc_f     multi-cycle RV32IMF
//
// Memory map (physical; Harvard, as on every SoC in the project):
//   0x0000_0000  IMEM (instruction port) / DMEM (data port), block RAM
//   0x1000_0000  CONSOLE  +0 TX (write a byte)  +4 STATUS (bit0 = ready)
//   0x1001_0000  TIMER    +0 MTIME  +4 MTIMECMP  +8 EXPIRED   (TIMER=1)
//   0x1002_0000  GPIO     +0 OUT [1:0] (LEDs)  +4 IN [1:0] (buttons) (GPIO=1)
//   0x2000_0000  SYSCON   write: halt, value = exit code
//
// The console is a byte stream (con_valid / con_data / con_ready): the
// top level serializes it onto a pin, or hands it to the PS. The host
// port (h_*) reaches both memories through their second BRAM port, in
// this clock domain, so the PS can load a program while the core is
// held in reset.
// =====================================================================
`default_nettype none

module oz_rv_soc #(
    parameter CORE        = 0,
    parameter M_EXT       = 1,
    parameter A_EXT       = 1,
    parameter HAS_U       = 1,
    parameter HAS_S       = 1,
    parameter MMU         = 1,
    parameter TLB_ENTRIES = 4,
    parameter BPRED       = 1,
    parameter BP_IDX_BITS = 5,
    parameter CACHES      = 1,
    parameter LINE_WORDS  = 8,
    parameter I_LINES     = 32,
    parameter D_LINES     = 64,
    parameter IMEM_WORDS  = 4096,
    parameter DMEM_WORDS  = 4096,
    parameter IMEM_INIT   = "",
    parameter DMEM_INIT   = "",
    parameter TIMER       = 1,
    parameter GPIO        = 1,
    parameter ZBA         = 1,         // bit manipulation (pipeline only)
    parameter ZBB         = 1,
    parameter ZBC         = 1,
    parameter ZBS         = 1,
    parameter V_EXT       = 0,         // vector unit, Zve32x (pipeline only)
    parameter VLEN        = 128,
    parameter ZICNTR      = 1          // cycle / instret / event counters (pipeline only)
) (
    input  wire        clk,
    input  wire        rst,
    // ---- console byte stream ----
    output wire        con_valid,
    output wire [7:0]  con_data,
    input  wire        con_ready,
    // ---- GPIO ----
    output reg  [1:0]  gpio_out,
    input  wire [1:0]  gpio_in,
    // ---- status ----
    output reg         halted,
    output reg  [31:0] exit_code,
    output wire        retire,         // pipeline only (0 on multi-cycle)
    // ---- host port into the memories (this clock domain) ----
    input  wire        h_en,
    input  wire        h_dmem,         // 0 = IMEM, 1 = DMEM
    input  wire        h_we,
    input  wire [15:0] h_addr,         // word index
    input  wire [31:0] h_wdata,
    output wire [31:0] h_rdata         // valid the cycle after h_en
);
    localparam IAW = $clog2(IMEM_WORDS);
    localparam DAW = $clog2(DMEM_WORDS);
    localparam LW  = 32*LINE_WORDS;

    // ---------------------------------------------------------------
    // Core-side buses (one shape for every core)
    // ---------------------------------------------------------------
    wire [31:0] daddr, dwdata;
    wire [3:0]  dwe;
    wire        dwr;                   // a data write commits this cycle
    wire        timer_irq;
    reg  [31:0] mmio_rdata;

    // ---- address decode ----
    wire sel_ram   = (daddr[31:28] == 4'h0);
    wire sel_io    = (daddr[31:28] == 4'h1);
    wire sel_con   = sel_io && (daddr[19:16] == 4'h0);
    wire sel_timer = sel_io && (daddr[19:16] == 4'h1);
    wire sel_gpio  = sel_io && (daddr[19:16] == 4'h2);
    wire sel_sys   = (daddr[31:28] == 4'h2);

    // ---- the two block RAMs; port B is the host's ----
    wire          ia_en, da_en;
    wire [3:0]    ia_we, da_we;
    wire [IAW-1:0] ia_addr;
    wire [DAW-1:0] da_addr;
    wire [31:0]   ia_wdata, da_wdata, ia_rdata, da_rdata, ib_rdata, db_rdata;

    oz_dpram #(.WORDS(IMEM_WORDS), .INIT_FILE(IMEM_INIT)) u_imem (
        .clk(clk),
        .en_a(ia_en), .we_a(ia_we), .addr_a(ia_addr), .wdata_a(ia_wdata), .rdata_a(ia_rdata),
        .en_b(h_en & ~h_dmem), .we_b({4{h_we}}), .addr_b(h_addr[IAW-1:0]),
        .wdata_b(h_wdata), .rdata_b(ib_rdata));
    oz_dpram #(.WORDS(DMEM_WORDS), .INIT_FILE(DMEM_INIT)) u_dmem (
        .clk(clk),
        .en_a(da_en), .we_a(da_we), .addr_a(da_addr), .wdata_a(da_wdata), .rdata_a(da_rdata),
        .en_b(h_en & h_dmem), .we_b({4{h_we}}), .addr_b(h_addr[DAW-1:0]),
        .wdata_b(h_wdata), .rdata_b(db_rdata));
    reg h_dmem_q;
    always @(posedge clk) if (h_en) h_dmem_q <= h_dmem;
    assign h_rdata = h_dmem_q ? db_rdata : ib_rdata;

    // ---------------------------------------------------------------
    // The core
    // ---------------------------------------------------------------
    generate if (CORE == 0) begin : g_pipe
        wire [31:0] iaddr, irdata, ram_rdata;
        wire        ireq, iready, dreq, ram_ready;
        wire [31:0] drdata = sel_ram ? ram_rdata : mmio_rdata;

        cpu_pipe_u #(.TLB_ENTRIES(TLB_ENTRIES), .BPRED(BPRED), .BP_IDX_BITS(BP_IDX_BITS),
                     .M_EXT(M_EXT), .A_EXT(A_EXT), .HAS_U(HAS_U), .HAS_S(HAS_S), .MMU(MMU),
                     .ZBA(ZBA), .ZBB(ZBB), .ZBC(ZBC), .ZBS(ZBS),
                     .V_EXT(V_EXT), .VLEN(VLEN), .ZICNTR(ZICNTR)) u_core (
            .clk(clk), .rst(rst), .timer_irq(timer_irq), .mtime(64'd0), .halt(halted),
            .i_addr(iaddr), .i_req(ireq), .i_rdata(irdata), .i_ready(iready),
            .d_addr(daddr), .d_req(dreq), .d_we(dwe), .d_wdata(dwdata),
            .d_rdata(drdata), .d_ready(sel_ram ? ram_ready : 1'b1),
            .pc_out(), .retire(retire));
        assign dwr = dreq & (|dwe);

        // ---- I side and D side: cache (or bridge) -> burst engine -> BRAM ----
        wire          im_req, im_we, im_done, dm_req, dm_we, dm_done;
        wire [31:0]   im_addr, dm_addr;
        wire [3:0]    im_mask, dm_mask;
        wire [LW-1:0] im_wdata, im_rdata, dm_wdata, dm_rdata;

        if (CACHES) begin : g_cache
            icache #(.LINES(I_LINES), .LINE_WORDS(LINE_WORDS)) u_icache (
                .clk(clk), .rst(rst), .addr(iaddr), .req(ireq), .rdata(irdata), .ready(iready),
                .m_req(im_req), .m_addr(im_addr), .m_done(im_done), .m_rdata(im_rdata));
            assign im_we = 1'b0; assign im_mask = 4'b0; assign im_wdata = {LW{1'b0}};
            dcache #(.LINES(D_LINES), .LINE_WORDS(LINE_WORDS)) u_dcache (
                .clk(clk), .rst(rst), .addr(daddr), .req(dreq & sel_ram), .we(dwe), .wdata(dwdata),
                .rdata(ram_rdata), .ready(ram_ready),
                .m_req(dm_req), .m_we(dm_we), .m_addr(dm_addr), .m_wdata(dm_wdata),
                .m_done(dm_done), .m_rdata(dm_rdata));
            assign dm_mask = 4'b1111;
        end else begin : g_bridge
            mem_bridge #(.LINE_WORDS(LINE_WORDS)) u_ibridge (
                .clk(clk), .rst(rst), .addr(iaddr), .req(ireq), .we(4'b0), .wdata(32'd0),
                .rdata(irdata), .ready(iready),
                .m_req(im_req), .m_we(im_we), .m_addr(im_addr), .m_wmask(im_mask),
                .m_wdata(im_wdata), .m_done(im_done), .m_rdata(im_rdata));
            mem_bridge #(.LINE_WORDS(LINE_WORDS)) u_dbridge (
                .clk(clk), .rst(rst), .addr(daddr), .req(dreq & sel_ram), .we(dwe), .wdata(dwdata),
                .rdata(ram_rdata), .ready(ram_ready),
                .m_req(dm_req), .m_we(dm_we), .m_addr(dm_addr), .m_wmask(dm_mask),
                .m_wdata(dm_wdata), .m_done(dm_done), .m_rdata(dm_rdata));
        end

        oz_burst_mem #(.WORDS(IMEM_WORDS), .LINE_WORDS(LINE_WORDS)) u_iburst (
            .clk(clk), .rst(rst), .req(im_req), .we(im_we), .burst(CACHES != 0),
            .addr(im_addr), .wmask(im_mask), .wdata(im_wdata), .done(im_done), .rdata(im_rdata),
            .ram_en(ia_en), .ram_we(ia_we), .ram_addr(ia_addr), .ram_wdata(ia_wdata),
            .ram_rdata(ia_rdata));
        oz_burst_mem #(.WORDS(DMEM_WORDS), .LINE_WORDS(LINE_WORDS)) u_dburst (
            .clk(clk), .rst(rst), .req(dm_req), .we(dm_we), .burst(CACHES != 0),
            .addr(dm_addr), .wmask(dm_mask), .wdata(dm_wdata), .done(dm_done), .rdata(dm_rdata),
            .ram_en(da_en), .ram_we(da_we), .ram_addr(da_addr), .ram_wdata(da_wdata),
            .ram_rdata(da_rdata));
    end else begin : g_mc
        // The multi-cycle cores were written against registered block RAM
        // (Step 23): they hold the address and read the word a cycle later.
        wire [31:0] iaddr;
        wire [31:0] drdata = sel_ram ? da_rdata : mmio_rdata;
        if (CORE == 1) begin : g_mc_base
            cpu_mc u_core (.clk(clk), .rst(rst), .timer_irq(timer_irq), .ext_irq(1'b0),
                .halt(halted), .imem_addr(iaddr), .imem_rdata(ia_rdata),
                .dmem_addr(daddr), .dmem_we(dwe), .dmem_re(), .dmem_wdata(dwdata),
                .dmem_rdata(drdata), .pc_out());
        end else if (CORE == 2) begin : g_mc_c
            cpu_mc_c u_core (.clk(clk), .rst(rst), .timer_irq(timer_irq), .ext_irq(1'b0),
                .halt(halted), .imem_addr(iaddr), .imem_rdata(ia_rdata),
                .dmem_addr(daddr), .dmem_we(dwe), .dmem_re(), .dmem_wdata(dwdata),
                .dmem_rdata(drdata), .pc_out());
        end else begin : g_mc_f
            cpu_mc_f u_core (.clk(clk), .rst(rst), .timer_irq(timer_irq), .ext_irq(1'b0),
                .halt(halted), .imem_addr(iaddr), .imem_rdata(ia_rdata),
                .dmem_addr(daddr), .dmem_we(dwe), .dmem_re(), .dmem_wdata(dwdata),
                .dmem_rdata(drdata), .pc_out());
        end
        assign dwr = |dwe;
        assign retire = 1'b0;
        assign ia_en = 1'b1; assign ia_we = 4'b0; assign ia_wdata = 32'd0;
        assign ia_addr = iaddr[IAW+1:2];
        assign da_en = 1'b1; assign da_we = sel_ram ? dwe : 4'b0; assign da_wdata = dwdata;
        assign da_addr = daddr[DAW+1:2];
    end endgenerate

    // ---------------------------------------------------------------
    // Peripherals
    // ---------------------------------------------------------------
    // console: a write to +0 hands the byte out (software polls STATUS)
    assign con_valid = dwr & sel_con & (daddr[3:0] == 4'h0);
    assign con_data  = dwdata[7:0];

    wire [31:0] timer_rdata;
    generate if (TIMER) begin : g_timer
        timer u_timer (.clk(clk), .rst(rst), .sel(sel_timer), .we(dwr & sel_timer),
            .addr(daddr[7:0]), .wdata(dwdata), .rdata(timer_rdata), .irq(timer_irq));
    end else begin : g_no_timer
        assign timer_rdata = 32'd0; assign timer_irq = 1'b0;
    end endgenerate

    always @(posedge clk) begin
        if (rst) begin
            gpio_out <= 2'b00; halted <= 1'b0; exit_code <= 32'd0;
        end else begin
            if (GPIO && dwr && sel_gpio && daddr[3:0] == 4'h0) gpio_out <= dwdata[1:0];
            if (dwr && sel_sys && !halted) begin halted <= 1'b1; exit_code <= dwdata; end
        end
    end

    always @(*) begin
        mmio_rdata = 32'd0;
        if (sel_con && daddr[3:0] == 4'h4)        mmio_rdata = {31'd0, con_ready};
        else if (sel_timer)                       mmio_rdata = timer_rdata;
        else if (GPIO && sel_gpio && daddr[3:0] == 4'h0) mmio_rdata = {30'd0, gpio_out};
        else if (GPIO && sel_gpio && daddr[3:0] == 4'h4) mmio_rdata = {30'd0, gpio_in};
    end
endmodule

`default_nettype wire
