// =====================================================================
// soc_pipe_c.v  -  the unified pipeline behind I/D caches and SLOW memory
// ---------------------------------------------------------------------
// Step 43. The same cpu_pipe_u as Step 42, unchanged, but the ideal
// memories are gone: instructions and data live in mem_slow, a DDR-like
// model with a LATENCY-cycle first word and one-word-per-cycle bursts.
// Between core and memory sit either
//
//   CACHE_EN=1 : icache (I-port) and a write-back dcache (D-port), or
//   CACHE_EN=0 : mem_bridge on each port -- every access pays LATENCY
//
// so the two configurations differ ONLY in the caches. MMIO bypasses
// the D-side path entirely and answers in one cycle.
//
//   0x0000_0000  RAM    (I: instruction memory; D: data memory -- Harvard)
//   0x1000_0000  UART   (+0 TX, +4 STATUS)
//   0x1001_0000  TIMER  (+0 MTIME, +4 MTIMECMP)
//   0x2000_0000  SYSCON (write -> halt)
// =====================================================================
`default_nettype none

module soc_pipe_c #(
    parameter CACHE_EN     = 1,
    parameter LATENCY      = 10,
    parameter LINE_WORDS   = 8,          // 32-byte lines
    parameter I_LINES      = 32,         // 1 KiB I-cache
    parameter D_LINES      = 64,         // 2 KiB D-cache
    parameter ROM_WORDS    = 4096,
    parameter RAM_WORDS    = 8192,
    parameter IMEM_INIT    = "",
    parameter DMEM_INIT    = "",
    parameter TLB_ENTRIES  = 4,
    parameter BPRED        = 1,
    parameter VLEN         = 128,
    parameter ZICNTR       = 1,          // cycle / instret / event counters (Step 48)
    parameter CLKS_PER_BIT = 1085
) (
    input  wire clk,
    input  wire rst,
    output wire uart_tx_pin,
    output wire halted
);
    localparam LW = 32*LINE_WORDS;

    wire [31:0] iaddr, irdata, daddr, dwdata, drdata;
    wire        ireq, iready, dreq, dready;
    wire [3:0]  dwe;
    wire        timer_irq, halt_q, retire;

`ifdef PIPE_C_BOARD
    // the Linux board's core (fpga_top_linux, Steps 57-58) behind these
    // caches, for tools/bench; each option can be turned off with
    // -DBRD_<name>=0 to measure what it costs (BPRED stays a parameter)
`ifndef BRD_DIV_ITER
`define BRD_DIV_ITER 1
`endif
`ifndef BRD_MUL_2C
`define BRD_MUL_2C 1
`endif
`ifndef BRD_XLATE_2C
`define BRD_XLATE_2C 1
`endif
`ifndef BRD_REG_REDIRECT
`define BRD_REG_REDIRECT 1
`endif
`ifndef BRD_IF_PAGE
`define BRD_IF_PAGE 1
`endif
    cpu_pipe_u #(.TLB_ENTRIES(TLB_ENTRIES), .BPRED(BPRED), .VLEN(VLEN), .ZICNTR(ZICNTR), .V_EXT(0),
                 .ZBA(0), .ZBB(0), .ZBC(0), .ZBS(0),
                 .DIV_ITER(`BRD_DIV_ITER), .MUL_2C(`BRD_MUL_2C), .AGU(1), .XLATE_2C(`BRD_XLATE_2C),
                 .VALID_FLUSH(1), .REG_REDIRECT(`BRD_REG_REDIRECT), .FWD_PRE(1),
                 .IF_PAGE(`BRD_IF_PAGE), .HPM_LATE(1)) u_core (
`else
    cpu_pipe_u #(.TLB_ENTRIES(TLB_ENTRIES), .BPRED(BPRED), .VLEN(VLEN), .ZICNTR(ZICNTR)) u_core (
`endif
        .clk(clk), .rst(rst), .timer_irq(timer_irq), .mtime(64'd0), .meip(1'b0), .seip(1'b0), .fencei_req(), .fencei_ack(1'b1), .halt(halt_q),
        .i_addr(iaddr), .i_req(ireq), .i_rdata(irdata), .i_ready(iready),
        .d_addr(daddr), .d_req(dreq), .d_we(dwe), .d_wdata(dwdata),
        .d_rdata(drdata), .d_ready(dready),
        .i_addr_next(iaddr_next), .d_addr_next(daddr_next), .d_hint_ok(dhint_ok),
        .pc_out(), .retire(retire)
    );

    // ---- address decode (D side) ----
    wire sel_ram   = (daddr[31:28] == 4'h0);
    wire sel_uart  = (daddr[31:28] == 4'h1) && (daddr[16] == 1'b0);
    wire sel_timer = (daddr[31:28] == 4'h1) && (daddr[16] == 1'b1);
    wire sel_sys   = (daddr[31:28] == 4'h2);
    wire wr_any    = dreq & (|dwe);               // MMIO writes complete at once

    // ---- slow memories ----
    wire          im_req, im_we, im_done, dm_req, dm_we, dm_done;
    wire [31:0]   im_addr, dm_addr;
    wire [3:0]    im_mask, dm_mask;
    wire [LW-1:0] im_wdata, im_rdata, dm_wdata, dm_rdata;

    mem_slow #(.WORDS(ROM_WORDS), .LINE_WORDS(LINE_WORDS), .LATENCY(LATENCY),
               .INIT_FILE(IMEM_INIT)) u_imem (
        .clk(clk), .rst(rst), .req(im_req), .we(im_we), .burst(CACHE_EN != 0),
        .addr(im_addr), .wmask(im_mask), .wdata(im_wdata), .done(im_done), .rdata(im_rdata));
    mem_slow #(.WORDS(RAM_WORDS), .LINE_WORDS(LINE_WORDS), .LATENCY(LATENCY),
               .INIT_FILE(DMEM_INIT)) u_dmem (
        .clk(clk), .rst(rst), .req(dm_req), .we(dm_we), .burst(CACHE_EN != 0),
        .addr(dm_addr), .wmask(dm_mask), .wdata(dm_wdata), .done(dm_done), .rdata(dm_rdata));

    wire [31:0] ram_rdata; wire ram_ready;
    wire [31:0] iaddr_next, daddr_next;   // the core's hints (Step 59)
    wire        dhint_ok;
    generate if (CACHE_EN) begin : g_cache
`ifdef PIPE_C_BOARD
        // the board's block-RAM caches (Step 59), on the core's hints
        icache_b #(.LINES(I_LINES), .LINE_WORDS(LINE_WORDS)) u_icache (
            .clk(clk), .rst(rst), .addr(iaddr), .req(ireq), .rdata(irdata), .ready(iready),
            .hint(iaddr_next), .inval(1'b0),
            .m_req(im_req), .m_addr(im_addr), .m_done(im_done), .m_rdata(im_rdata));
`else
        icache #(.LINES(I_LINES), .LINE_WORDS(LINE_WORDS)) u_icache (
            .clk(clk), .rst(rst), .addr(iaddr), .req(ireq), .rdata(irdata), .ready(iready), .inval(1'b0),
            .m_req(im_req), .m_addr(im_addr), .m_done(im_done), .m_rdata(im_rdata));
`endif
        assign im_we = 1'b0; assign im_mask = 4'b0; assign im_wdata = {LW{1'b0}};

`ifdef PIPE_C_BOARD
        dcache_b #(.LINES(D_LINES), .LINE_WORDS(LINE_WORDS)) u_dcache (
            .clk(clk), .rst(rst), .addr(daddr), .req(dreq & sel_ram), .we(dwe), .wdata(dwdata),
            .rdata(ram_rdata), .ready(ram_ready), .hint(daddr_next), .hint_ok(dhint_ok),
            .clean(1'b0), .clean_done(),
            .m_req(dm_req), .m_we(dm_we), .m_addr(dm_addr), .m_wdata(dm_wdata),
            .m_done(dm_done), .m_rdata(dm_rdata));
`else
        dcache #(.LINES(D_LINES), .LINE_WORDS(LINE_WORDS)) u_dcache (
            .clk(clk), .rst(rst), .addr(daddr), .req(dreq & sel_ram), .we(dwe), .wdata(dwdata),
            .rdata(ram_rdata), .ready(ram_ready), .clean(1'b0), .clean_done(),
            .m_req(dm_req), .m_we(dm_we), .m_addr(dm_addr), .m_wdata(dm_wdata),
            .m_done(dm_done), .m_rdata(dm_rdata));
`endif
        assign dm_mask = 4'b1111;

`ifndef VERILATOR
`ifndef PIPE_C_BOARD
        // testbench helper: the CURRENT value of a RAM word. With a
        // write-back cache the newest copy may still be in the cache, not
        // in main memory, so look there first. (Icarus testbenches only:
        // Verilator cannot resolve these references, and tools/bench's
        // Verilator models do not need them.)
        localparam OFF = $clog2(LINE_WORDS) + 2, IDX = $clog2(D_LINES);
        function [31:0] peek;
            input [31:0] pa;
            begin
                if (u_dcache.valid[pa[OFF+IDX-1:OFF]] &&
                    u_dcache.tags[pa[OFF+IDX-1:OFF]] == pa[31:OFF+IDX])
                    peek = u_dcache.lines[pa[OFF+IDX-1:OFF]][32*pa[OFF-1:2] +: 32];
                else
                    peek = u_dmem.mem[pa[$clog2(RAM_WORDS)+1:2]];
            end
        endfunction
`endif
`endif
    end else begin : g_nocache
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
    end endgenerate

    // ---- peripherals (single-cycle) ----
    wire [31:0] uart_rdata, timer_rdata;
    uart_hw #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart (
        .clk(clk), .rst(rst), .sel(dreq & sel_uart), .we(sel_uart & wr_any),
        .addr(daddr[7:0]), .wdata(dwdata), .rdata(uart_rdata), .tx(uart_tx_pin)
    );
    timer u_timer (
        .clk(clk), .rst(rst), .sel(dreq & sel_timer), .we(sel_timer & wr_any),
        .addr(daddr[7:0]), .wdata(dwdata), .rdata(timer_rdata), .irq(timer_irq)
    );
    reg halt_r;
    always @(posedge clk)
        if (rst) halt_r <= 1'b0;
        else if (sel_sys & wr_any) halt_r <= 1'b1;
    assign halt_q = halt_r;
    assign halted = halt_r;

    assign dready = sel_ram ? ram_ready : 1'b1;
    assign drdata = sel_uart  ? uart_rdata  :
                    sel_timer ? timer_rdata : ram_rdata;

endmodule

`default_nettype wire
