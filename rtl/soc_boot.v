// =====================================================================
// soc_boot.v  -  a boot platform: ROM + RAM + standard devices
// ---------------------------------------------------------------------
// Step 49. Every SoC so far put the program into the instruction ROM at
// time zero. This one boots like a real machine: the only thing in it at
// power-on is a boot ROM, which loads programs over the serial port into
// RAM and runs them. Three things make that possible:
//
//   * ONE memory behind both ports. The I-port fetches from the same RAM
//     the D-port writes, so a stored byte can become an instruction (the
//     core's FENCE.I refetches whatever is behind it).
//   * the standard devices, at the addresses of QEMU's `virt` board, so
//     the device tree describing them uses compatible strings that
//     OpenSBI, U-Boot and Linux already have drivers for:
//
//       0x0000_1000  boot ROM      ROM_WORDS*4 bytes (reset vector)
//       0x0010_0000  test device   "sifive,test0": 0x5555 = power off,
//                                   0x3333 | code << 16 = fail with code,
//                                   0x7777 = reset (back into the ROM)
//       0x0200_0000  CLINT         "sifive,clint0"  (msip / mtimecmp / mtime)
//       0x0c00_0000  PLIC          "sifive,plic-1.0.0", contexts M and S (Step 50)
//       0x1000_0000  UART          "ns16550a", reg-shift 2, PLIC source 10
//       0x8000_0000  RAM           RAM_WORDS*4 bytes
//
//   * mtime wired into the core as the `time` CSR.
//
// Step 50 adds what a kernel expects of the hardware underneath it: the
// PLIC, whose two contexts drive the core's MEIP and SEIP; the same memory
// map handed to the core as PMA regions, so an access to a hole in it (or a
// store to the ROM) is a precise access fault rather than a read of 0; and
// a walker that faults on clear A / D bits (SVADE).
//
// Step 51: the memory system, MEMSYS --
//   0  ideal: combinational arrays, always ready (simulation only)
//   1  I-cache + write-back D-cache, both refilling through one line port
//      (line_arb) from block RAM: the ROM and RAM_WORDS of RAM, read
//      through oz_burst_mem with a registered output -- what fits an FPGA
//   2  the same caches, the ROM in block RAM, and the RAM out over an AXI4
//      burst master (axi4_line_master) -- DDR, with megabytes of room --
//      except its first OCM_WORDS (the firmware's 16 KiB: the ROM's data
//      and stack, then the resident SBI), which stay in on-chip block RAM
//      like the Zynq's OCM. The ROM's receive loop has to keep up with the
//      UART; behind DDR latency its cache misses made it fall behind.
//      AXI_DATA_W = 64 (Step 54) makes that port the shape of a Zynq
//      S_AXI_HP port: 64-bit beats, 4 a line (AXI3 needs only the low 4 bits
//      of the burst length, and IDs of 0).
// With caches, FENCE.I is no longer just a refetch: the core holds it in EX
// until the D-cache has written every dirty line back and the I-cache has
// been invalidated (fencei_req / fencei_ack), so code stored through the
// D-cache is what the I-cache refills.
//
// A reset through the test device (SBI system_reset -> 0x7777) resets the
// core, the caches and the devices but not the memories, like a warm
// reset: the ROM starts over and can load the next program.
// =====================================================================
`default_nettype none

module soc_boot #(
    parameter ROM_WORDS    = 4096,        // 16 KiB boot ROM
    parameter RAM_WORDS    = 65536,       // 256 KiB RAM (MEMSYS 2: the DDR window)
    parameter BOOTROM_INIT = "",
    parameter [15:0] UART_DIV = 16'd1,    // divisor latch at reset
    parameter TLB_ENTRIES  = 4,
    parameter BPRED        = 1,
    parameter ZB_EXT       = 1,           // Zba/Zbb/Zbc/Zbs; 0 leaves them out (and the DT must say so)
    parameter V_EXT        = 0,           // no vectors: this platform is for scalar OSes
    parameter SVADE        = 1,           // page faults on clear A / D bits
    parameter MEMSYS       = 0,           // 0 ideal, 1 caches + block RAM, 2 caches + AXI4
    parameter LINE_WORDS   = 8,           // 32-byte lines
    parameter I_LINES      = 64,          // 2 KiB I-cache
    parameter D_LINES      = 64,          // 2 KiB D-cache
    parameter [31:0] AXI_OFFSET = 32'd0,  // RAM_BASE + x appears at AXI address x + this
    parameter OCM_WORDS    = 4096,        // MEMSYS 2: on-chip RAM at RAM_BASE (16 KiB)
    parameter AXI_DATA_W   = 32,          // MEMSYS 2: 32, or 64 for a Zynq S_AXI_HP port
    parameter DIV_ITER     = 0            // 1: the iterative divider (cpu_pipe_u, Step 57): a quarter of the logic
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        uart_rx_pin,
    output wire        uart_tx_pin,
    output wire        halted,            // the test device was written
    output wire [15:0] exit_code,         // 0 = powered off cleanly
    output wire        warm_reset,        // a reset through the test device is under way
    // ---- AXI4 master: the RAM, when MEMSYS = 2 (idle otherwise) ----
    output wire [31:0] m_axi_awaddr,
    output wire [7:0]  m_axi_awlen,
    output wire [2:0]  m_axi_awsize,
    output wire [1:0]  m_axi_awburst,
    output wire [3:0]  m_axi_awcache,
    output wire [2:0]  m_axi_awprot,
    output wire        m_axi_awvalid,
    input  wire        m_axi_awready,
    output wire [AXI_DATA_W-1:0]   m_axi_wdata,
    output wire [AXI_DATA_W/8-1:0] m_axi_wstrb,
    output wire        m_axi_wlast,
    output wire        m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire [1:0]  m_axi_bresp,
    input  wire        m_axi_bvalid,
    output wire        m_axi_bready,
    output wire [31:0] m_axi_araddr,
    output wire [7:0]  m_axi_arlen,
    output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,
    output wire [3:0]  m_axi_arcache,
    output wire [2:0]  m_axi_arprot,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [AXI_DATA_W-1:0]   m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rlast,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready
);
    localparam [31:0] ROM_BASE = 32'h0000_1000, ROM_BYTES = ROM_WORDS * 4;
    localparam LW = 32 * LINE_WORDS;
    // RAM held in this module (MEMSYS 2: only the on-chip part)
    localparam LOCAL_RAM_WORDS = (MEMSYS == 2) ? OCM_WORDS : RAM_WORDS;

    // the memory map, as the core's PMA checker sees it: {X, W, R}
    localparam [8*32-1:0] PMA_BASE = {32'd0, 32'd0, 32'h8000_0000, 32'h1000_0000,
                                      32'h0c00_0000, 32'h0200_0000, 32'h0010_0000, ROM_BASE};
    localparam [8*32-1:0] PMA_SIZE = {32'd0, 32'd0, RAM_WORDS * 32'd4, 32'h0000_0100,
                                      32'h0400_0000, 32'h0001_0000, 32'h0000_1000, ROM_BYTES};
    localparam [8*3-1:0]  PMA_ATTR = {3'b000, 3'b000, 3'b111, 3'b011,
                                      3'b011, 3'b011, 3'b011, 3'b101};

    wire [31:0] iaddr, daddr, dwdata;
    reg  [31:0] irdata, drdata;
    wire        ireq, dreq, iready, dready;
    wire [3:0]  dwe;
    wire        timer_irq, retire;
    wire [63:0] mtime;
    wire        sys_rst;                  // power-on reset, or a warm reset
    wire        fencei_req, fencei_ack;
    wire [31:0] clint_rdata, uart_rdata, plic_rdata;
    wire        uart_irq;

    wire [1:0] eip;                       // PLIC contexts: 0 = M, 1 = S
    cpu_pipe_u #(.RESET_PC(ROM_BASE), .TLB_ENTRIES(TLB_ENTRIES), .BPRED(BPRED),
                 .V_EXT(V_EXT), .SVADE(SVADE), .DIV_ITER(DIV_ITER),
                 .ZBA(ZB_EXT), .ZBB(ZB_EXT), .ZBC(ZB_EXT), .ZBS(ZB_EXT), .PMA_N(6), .PMA_BASE(PMA_BASE),
                 .PMA_SIZE(PMA_SIZE), .PMA_ATTR(PMA_ATTR)) u_core (
        .clk(clk), .rst(sys_rst), .timer_irq(timer_irq), .mtime(mtime),
        .meip(eip[0]), .seip(eip[1]), .halt(halted),
        .fencei_req(fencei_req), .fencei_ack(fencei_ack),
        .i_addr(iaddr), .i_req(ireq), .i_rdata(irdata), .i_ready(iready),
        .d_addr(daddr), .d_req(dreq), .d_we(dwe), .d_wdata(dwdata),
        .d_rdata(drdata), .d_ready(dready),
        .pc_out(), .retire(retire)
    );

    // ---- the two memories ----
    reg [31:0] rom [0:ROM_WORDS-1];
    reg [31:0] ram [0:LOCAL_RAM_WORDS-1];
    integer k;
    initial begin
        for (k = 0; k < ROM_WORDS; k = k + 1) rom[k] = 32'd0;
        for (k = 0; k < LOCAL_RAM_WORDS; k = k + 1) ram[k] = 32'd0;
        if (BOOTROM_INIT != "") $readmemh(BOOTROM_INIT, rom);
    end
    function in_rom; input [31:0] a; in_rom = (a >= ROM_BASE) && (a - ROM_BASE < ROM_BYTES); endfunction
    function in_ram; input [31:0] a; in_ram = (a[31:28] == 4'h8); endfunction
    function [$clog2(ROM_WORDS)-1:0] rom_idx; input [31:0] a; rom_idx = (a - ROM_BASE) >> 2; endfunction
    function [$clog2(LOCAL_RAM_WORDS > 1 ? LOCAL_RAM_WORDS : 2)-1:0] ram_idx;
        input [31:0] a; ram_idx = a >> 2; endfunction

    // ---- D-side decode ----
    wire sel_rom   = in_rom(daddr);
    wire sel_ram   = in_ram(daddr);
    wire sel_test  = (daddr[31:12] == 20'h00100);
    wire sel_clint = (daddr[31:16] == 16'h0200);
    wire sel_uart  = (daddr[31:12] == 20'h10000);
    wire sel_plic  = (daddr[31:26] == 6'b000011);
    wire wr_any    = dreq & (|dwe);
    wire [31:0] mmio_rdata = sel_uart  ? uart_rdata :
                             sel_clint ? clint_rdata :
                             sel_plic  ? plic_rdata  : 32'd0;

    // (array reads as continuous assigns: inside always @(*) Icarus would
    //  re-run the block on every write to either array -- 5x slower)
    generate if (MEMSYS == 0) begin : g_ideal
        wire [31:0] irom = rom[rom_idx(iaddr)], iram = ram[ram_idx(iaddr)];
        always @(*)
            irdata = in_rom(iaddr) ? irom :
                     in_ram(iaddr) ? iram : 32'd0;
        wire [$clog2(RAM_WORDS)-1:0] rw = ram_idx(daddr);
        always @(posedge clk)
            if (dreq && sel_ram) begin
                if (dwe[0]) ram[rw][7:0]   <= dwdata[7:0];
                if (dwe[1]) ram[rw][15:8]  <= dwdata[15:8];
                if (dwe[2]) ram[rw][23:16] <= dwdata[23:16];
                if (dwe[3]) ram[rw][31:24] <= dwdata[31:24];
            end
        wire [31:0] dram = ram[rw], drom = rom[rom_idx(daddr)];
        always @(*)
            drdata = sel_ram ? dram : sel_rom ? drom : mmio_rdata;
        assign iready = 1'b1;
        assign dready = 1'b1;
        assign fencei_ack = 1'b1;          // nothing to write back or invalidate
    end else begin : g_cached
        // ---- the caches ----
        wire          cacheable = sel_ram | sel_rom;
        wire          ic_mreq, ic_mdone, ic_ready, ic_inval;
        wire [31:0]   ic_maddr, ic_rdata;
        wire          dc_mreq, dc_mwe, dc_mdone, dc_ready, dc_clean, dc_clean_done;
        wire [31:0]   dc_maddr, dc_rdata;
        wire [LW-1:0] dc_mwdata, lm_rdata;
        icache #(.LINES(I_LINES), .LINE_WORDS(LINE_WORDS)) u_icache (
            .clk(clk), .rst(sys_rst), .addr(iaddr), .req(ireq), .rdata(ic_rdata),
            .ready(ic_ready), .inval(ic_inval),
            .m_req(ic_mreq), .m_addr(ic_maddr), .m_done(ic_mdone), .m_rdata(lm_rdata));
        dcache #(.LINES(D_LINES), .LINE_WORDS(LINE_WORDS)) u_dcache (
            .clk(clk), .rst(sys_rst), .addr(daddr), .req(dreq & cacheable), .we(dwe),
            .wdata(dwdata), .rdata(dc_rdata), .ready(dc_ready),
            .clean(dc_clean), .clean_done(dc_clean_done),
            .m_req(dc_mreq), .m_we(dc_mwe), .m_addr(dc_maddr), .m_wdata(dc_mwdata),
            .m_done(dc_mdone), .m_rdata(lm_rdata));
        always @(*) irdata = ic_rdata;
        always @(*) drdata = cacheable ? dc_rdata : mmio_rdata;
        assign iready = ic_ready;
        assign dready = cacheable ? dc_ready : 1'b1;

        // ---- FENCE.I: write back the D-cache, then invalidate the I-cache ----
        reg fi_done;
        always @(posedge clk)
            if (sys_rst || !fencei_req) fi_done <= 1'b0;
            else if (dc_clean_done)     fi_done <= 1'b1;
        assign dc_clean   = fencei_req & ~fi_done;
        assign ic_inval   = dc_clean & dc_clean_done;
        assign fencei_ack = fi_done;

        // ---- one line port, routed to the ROM or the RAM ----
        wire          lm_req, lm_we, lm_done;
        wire [31:0]   lm_addr;
        wire [LW-1:0] lm_wdata;
        line_arb #(.LW(LW)) u_arb (
            .clk(clk), .rst(sys_rst),
            .d_req(dc_mreq), .d_we(dc_mwe), .d_addr(dc_maddr), .d_wdata(dc_mwdata), .d_done(dc_mdone),
            .i_req(ic_mreq), .i_addr(ic_maddr), .i_done(ic_mdone),
            .m_req(lm_req), .m_we(lm_we), .m_addr(lm_addr), .m_wdata(lm_wdata), .m_done(lm_done));
        wire          to_rom   = in_rom(lm_addr);
        wire          to_local = (MEMSYS == 1) | (lm_addr - 32'h8000_0000 < LOCAL_RAM_WORDS * 4);
        wire          rom_done, ram_done, axi_done;
        wire [LW-1:0] rom_line, ram_line, axi_line;
        assign lm_done  = rom_done | ram_done | axi_done;
        assign lm_rdata = to_rom ? rom_line : to_local ? ram_line : axi_line;

        // the ROM: a block RAM with a registered read
        wire                         rom_en;
        wire [$clog2(ROM_WORDS)-1:0] rom_a;
        reg  [31:0]                  rom_q;
        always @(posedge clk) if (rom_en) rom_q <= rom[rom_a];
        oz_burst_mem #(.WORDS(ROM_WORDS), .LINE_WORDS(LINE_WORDS)) u_romport (
            .clk(clk), .rst(sys_rst), .req(lm_req & to_rom), .we(1'b0), .burst(1'b1),
            .addr(lm_addr - ROM_BASE), .wmask(4'd0), .wdata({LW{1'b0}}),
            .done(rom_done), .rdata(rom_line),
            .ram_en(rom_en), .ram_we(), .ram_addr(rom_a), .ram_wdata(), .ram_rdata(rom_q));

        // the RAM (MEMSYS 1) or its on-chip part (2): block RAM, byte lanes,
        // registered read (oz_dpram's template)
        begin : g_bram
            wire                         ram_en;
            wire [3:0]                   ram_we;
            wire [$clog2(LOCAL_RAM_WORDS)-1:0] ram_a;
            wire [31:0]                  ram_wd;
            reg  [31:0]                  ram_q;
            always @(posedge clk) if (ram_en) begin
                if (ram_we[0]) ram[ram_a][7:0]   <= ram_wd[7:0];
                if (ram_we[1]) ram[ram_a][15:8]  <= ram_wd[15:8];
                if (ram_we[2]) ram[ram_a][23:16] <= ram_wd[23:16];
                if (ram_we[3]) ram[ram_a][31:24] <= ram_wd[31:24];
                ram_q <= ram[ram_a];
            end
            oz_burst_mem #(.WORDS(LOCAL_RAM_WORDS), .LINE_WORDS(LINE_WORDS)) u_ramport (
                .clk(clk), .rst(sys_rst), .req(lm_req & ~to_rom & to_local), .we(lm_we), .burst(1'b1),
                .addr(lm_addr), .wmask(4'b1111), .wdata(lm_wdata),
                .done(ram_done), .rdata(ram_line),
                .ram_en(ram_en), .ram_we(ram_we), .ram_addr(ram_a), .ram_wdata(ram_wd),
                .ram_rdata(ram_q));
        end
        if (MEMSYS == 2) begin : g_axi
            axi4_line_master #(.LINE_WORDS(LINE_WORDS), .ADDR_OFFSET(AXI_OFFSET - 32'h8000_0000),
                              .DATA_W(AXI_DATA_W)) u_axi (
                .clk(clk), .rst(sys_rst), .req(lm_req & ~to_rom & ~to_local), .we(lm_we), .addr(lm_addr),
                .wdata(lm_wdata), .done(axi_done), .rdata(axi_line), .err(),
                .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize),
                .m_axi_awburst(m_axi_awburst), .m_axi_awcache(m_axi_awcache), .m_axi_awprot(m_axi_awprot),
                .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
                .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
                .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
                .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
                .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize),
                .m_axi_arburst(m_axi_arburst), .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot),
                .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
                .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
                .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready));
        end else begin : g_no_axi_line
            assign axi_done = 1'b0; assign axi_line = {LW{1'b0}};
        end
    end endgenerate

    // the AXI port is quiet unless the RAM is out there
    generate if (MEMSYS != 2) begin : g_no_axi
        assign m_axi_awaddr = 32'd0; assign m_axi_awlen = 8'd0; assign m_axi_awsize = 3'd0;
        assign m_axi_awburst = 2'd0; assign m_axi_awcache = 4'd0; assign m_axi_awprot = 3'd0;
        assign m_axi_awvalid = 1'b0; assign m_axi_wdata = {AXI_DATA_W{1'b0}};
        assign m_axi_wstrb = {AXI_DATA_W/8{1'b0}};
        assign m_axi_wlast = 1'b0; assign m_axi_wvalid = 1'b0; assign m_axi_bready = 1'b0;
        assign m_axi_araddr = 32'd0; assign m_axi_arlen = 8'd0; assign m_axi_arsize = 3'd0;
        assign m_axi_arburst = 2'd0; assign m_axi_arcache = 4'd0; assign m_axi_arprot = 3'd0;
        assign m_axi_arvalid = 1'b0; assign m_axi_rready = 1'b0;
    end endgenerate

    // ---- devices ----
    clint_sifive u_clint (
        .clk(clk), .rst(sys_rst), .sel(dreq & sel_clint), .we(wr_any),
        .addr(daddr[15:0]), .wdata(dwdata), .rdata(clint_rdata),
        .timer_irq(timer_irq), .soft_irq(), .mtime_o(mtime));
    uart16550 #(.DEF_DIV(UART_DIV)) u_uart (
        .clk(clk), .rst(sys_rst), .sel(dreq & sel_uart), .we(wr_any),
        .addr(daddr[4:0]), .wdata(dwdata), .rdata(uart_rdata),
        .rx(uart_rx_pin), .tx(uart_tx_pin), .irq(uart_irq));
    plic_sifive #(.SOURCES(31), .CONTEXTS(2)) u_plic (
        .clk(clk), .rst(sys_rst), .sel(dreq & sel_plic), .we(wr_any),
        .addr(daddr[25:0]), .wdata(dwdata), .rdata(plic_rdata),
        .src({21'd0, uart_irq, 9'd0}), .eip(eip));      // the UART is source 10

    // ---- the test device: power off (pass), fail with a code, or reset ----
    reg        halt_r;
    reg [15:0] code_r;
    reg [2:0]  wrst;                      // warm reset: held for a few cycles
    always @(posedge clk)
        if (rst) begin halt_r <= 1'b0; code_r <= 16'd0; wrst <= 3'd0; end
        else begin
            if (wrst != 3'd0) wrst <= wrst - 3'd1;
            if (sel_test & wr_any & ~halt_r & (wrst == 3'd0)) begin
                if (dwdata[15:0] == 16'h5555)      begin halt_r <= 1'b1; code_r <= 16'd0; end
                else if (dwdata[15:0] == 16'h3333) begin halt_r <= 1'b1;
                    code_r <= (dwdata[31:16] == 16'd0) ? 16'd1 : dwdata[31:16]; end
                else if (dwdata[15:0] == 16'h7777) wrst <= 3'd4;
            end
        end
    assign sys_rst    = rst | (wrst != 3'd0);
    assign warm_reset = (wrst != 3'd0);
    assign halted     = halt_r;
    assign exit_code  = code_r;
endmodule

`default_nettype wire
