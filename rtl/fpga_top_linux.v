// =====================================================================
// fpga_top_linux.v  -  the boot platform with PS DDR, for Linux on the board
// ---------------------------------------------------------------------
// Step 54. fpga_top_boot (Step 51) keeps the whole computer in the PL, so
// it has 128 KiB of RAM. This one is soc_boot with MEMSYS = 2: the ROM and
// the firmware's 16 KiB in block RAM, and 64 MiB of RAM in the PS's DDR3,
// reached through the Zynq's S_AXI_HP0 port -- 64-bit AXI3 straight into
// the DDR controller. The RISC-V's 0x8000_0000 is DDR 0x1000_0000, so its
// 64 MiB is 0x1000_0000 .. 0x13FF_FFFF of the board's 512 MB; the PS
// program (it only initialises the PS and DDR, from OCM) touches none of it.
//
// The PS7 is OpenZynq's ps7_gp0 (rtl/ps7_gp0.v there) with HP0_ENABLE = 1.
// The RISC-V and HP0 run on one clock, so the data path crosses no clock
// domain: FCLK1, which the PS program sets to IO PLL / 20 = 50 MHz
// (Step 58; Step 57 ran it at 11.11 MHz). nextpnr-xilinx puts this core at
// 43-51 MHz after routing depending on the placement seed, so the build
// keeps a seed that passes 50 (OpenZynq's project.mk). Divisor 27 is
// 115,741 baud. The board ROM, device tree and U-Boot know the clock from
// PLAT_CLOCK_HZ (build/boot/linux-board/).
//
// Also for size, the board build leaves out what the boot chain never uses:
// Zba/Zbb/Zbc/Zbs (the kernel, U-Boot and userland are rv32ima, and the DT
// says so), and the branch predictor; and divides in 33 cycles (DIV_ITER).
// For timing (Step 58): multiplies take 3 cycles with registers on both
// sides of the DSPs (MUL_2C), and loads and stores compute their address
// with their own adder (AGU), so the multiplier is off the D-TLB's path;
// and a load or store spends 2 cycles in EX, its D-TLB lookup registered
// before the faults and the commit it decides (XLATE_2C).
//
// The DDR is usable only once the PS has run ps7_init() -- and an HP0
// access to an untrained controller may never complete, which no PL reset
// can undo. So the core does not rely on when the PS happens to release
// HP0's reset: it stays in reset until the PS program says so, over
// M_AXI_GP0 (on FCLK0, at 0x4000_0000 in the PS map), after ps7_init()
// and ps7_post_config() have returned:
//
//   0x00  read: 0x5256_4653 ("RVFS", this bitstream)
//         write: bit 0 = run (1 releases the RISC-V, 0 holds it in reset)
//   0x04  read: bit 0 = run, bit 1 = the RISC-V has powered off
//
// Any other access completes too (reads 0), so no PS access can hang.
//
//   resetn   U19  K1, active low: restarts the RISC-V (the ROM, then a new image)
//   uart_tx  J18  JM1 pin 21 (3.3 V) -> a USB-serial adapter's RX
//   uart_rx  K19  JM1 pin 22 (3.3 V) <- the adapter's TX; GND on JM1 pin 3/4
//   led      R19  LED1: powered off (the test device)
//   led2     V13  LED2: dark while the RISC-V is held in reset, then a heartbeat
// =====================================================================
`default_nettype none

module fpga_top_linux #(
    parameter BOOTROM_INIT = "build/boot/linux-board/rom.hex",
    parameter RAM_WORDS    = 1 << 24,              // 64 MiB of DDR
    parameter [31:0] DDR_BASE = 32'h1000_0000,     // where it starts in the PS map
    parameter DIV_ITER     = 1,                    // the 32-cycle divider: the array dividers do not fit (Step 57)
    parameter ZB_EXT       = 0,                    // no Zba/Zbb/Zbc/Zbs: nothing that boots here uses them
    parameter BPRED        = 0,                    // no branch predictor: area, not correctness
    parameter MUL_2C       = 1,                    // multiplies registered both sides (Step 58)
    parameter AGU          = 1,                    // loads/stores get their own address adder (Step 58)
    parameter XLATE_2C     = 1,                    // a load/store: D-TLB lookup, registered, then its faults (Step 58)
    parameter VALID_FLUSH  = 1,                    // a flush clears the valid bits only (Step 58)
    parameter REG_REDIRECT = 1,                    // a taken branch redirects a cycle later (Step 58)
    parameter FWD_PRE      = 1,                    // forwarding compares registered a cycle early (Step 58)
    parameter IF_PAGE      = 1,                    // fetch through a registered page translation (Step 58)
    parameter HPM_LATE     = 1,                    // hpmcounter3..7 count a cycle late (Step 58)
    parameter CACHE_BRAM   = 1,                    // 16 + 16 KiB caches in block RAM (Step 59)
    parameter I_LINES      = 512,
    parameter D_LINES      = 512,
    parameter [15:0] UART_DIV = 16'd27             // 50 MHz / 16 / 27 = 115,741 baud
) (
    input  wire resetn,
    input  wire uart_rx,
    output wire uart_tx,
    output wire led,
    output wire led2
);
    // ---- the PS: FCLK0 + GP0 (unused), and S_AXI_HP0 into DDR ----
    wire        aclk, aresetn, hp_aresetn;
    wire        clk;                              // FCLK1: the RISC-V's clock, and HP0's
    wire [31:0] gp_awaddr, gp_wdata, gp_araddr;
    wire [3:0]  gp_wstrb;
    wire        gp_awvalid, gp_wvalid, gp_bready, gp_arvalid, gp_rready;
    reg         gp_bvalid = 1'b0, gp_rvalid = 1'b0;
    reg  [31:0] gp_rdata = 32'd0;
    reg         run = 1'b0;                       // FCLK0 domain, set by the PS
    wire        gp_awready = gp_awvalid & gp_wvalid & ~gp_bvalid;
    wire        gp_arready = gp_arvalid & ~gp_rvalid;

    wire [31:0] awaddr, araddr;
    wire [7:0]  awlen, arlen;
    wire [2:0]  awsize, arsize, awprot, arprot;
    wire [1:0]  awburst, arburst, bresp, rresp;
    wire [3:0]  awcache, arcache;
    wire [63:0] wdata, rdata;
    wire [7:0]  wstrb;
    wire        awvalid, awready, wlast, wvalid, wready, bvalid, bready;
    wire        arvalid, arready, rlast, rvalid, rready;

    ps7_gp0 #(.HP0_ENABLE(1)) u_ps7 (
        .aclk(aclk), .aresetn(aresetn), .fclk1(clk),
        .m_awaddr(gp_awaddr), .m_awvalid(gp_awvalid), .m_awready(gp_awready),
        .m_wdata(gp_wdata), .m_wstrb(gp_wstrb), .m_wvalid(gp_wvalid), .m_wready(gp_awready),
        .m_bresp(2'b00), .m_bvalid(gp_bvalid), .m_bready(gp_bready),
        .m_araddr(gp_araddr), .m_arvalid(gp_arvalid), .m_arready(gp_arready),
        .m_rdata(gp_rdata), .m_rresp(2'b00), .m_rvalid(gp_rvalid), .m_rready(gp_rready),
        .s_hp0_aclk(clk), .s_hp0_aresetn(hp_aresetn),
        .s_hp0_awid(6'd0), .s_hp0_awaddr(awaddr), .s_hp0_awlen(awlen[3:0]),
        .s_hp0_awsize(awsize[1:0]), .s_hp0_awburst(awburst), .s_hp0_awlock(2'b00),
        .s_hp0_awcache(awcache), .s_hp0_awprot(awprot), .s_hp0_awqos(4'd0),
        .s_hp0_awvalid(awvalid), .s_hp0_awready(awready),
        .s_hp0_wid(6'd0), .s_hp0_wdata(wdata), .s_hp0_wstrb(wstrb), .s_hp0_wlast(wlast),
        .s_hp0_wvalid(wvalid), .s_hp0_wready(wready),
        .s_hp0_bid(), .s_hp0_bresp(bresp), .s_hp0_bvalid(bvalid), .s_hp0_bready(bready),
        .s_hp0_arid(6'd0), .s_hp0_araddr(araddr), .s_hp0_arlen(arlen[3:0]),
        .s_hp0_arsize(arsize[1:0]), .s_hp0_arburst(arburst), .s_hp0_arlock(2'b00),
        .s_hp0_arcache(arcache), .s_hp0_arprot(arprot), .s_hp0_arqos(4'd0),
        .s_hp0_arvalid(arvalid), .s_hp0_arready(arready),
        .s_hp0_rid(), .s_hp0_rdata(rdata), .s_hp0_rresp(rresp), .s_hp0_rlast(rlast),
        .s_hp0_rvalid(rvalid), .s_hp0_rready(rready)
    );

    // GP0: the two registers, one response per request, on FCLK0
    wire       halted;
    reg  [1:0] halted_s = 2'b00;                  // -> FCLK0
    always @(posedge aclk) halted_s <= {halted_s[0], halted};
    always @(posedge aclk) begin
        if (!aresetn) begin gp_bvalid <= 1'b0; gp_rvalid <= 1'b0; run <= 1'b0; end
        else begin
            if (gp_awready) begin
                gp_bvalid <= 1'b1;
                if (gp_awaddr[7:2] == 6'd0 && gp_wstrb[0]) run <= gp_wdata[0];
            end else if (gp_bready) gp_bvalid <= 1'b0;
            if (gp_arready) begin
                gp_rvalid <= 1'b1;
                gp_rdata  <= (gp_araddr[7:2] == 6'd0) ? 32'h5256_4653 :
                             (gp_araddr[7:2] == 6'd1) ? {30'd0, halted_s[1], run} : 32'd0;
            end else if (gp_rready) gp_rvalid <= 1'b0;
        end
    end

    // ---- reset: K1, or the PS has not said run (DDR not initialised) ----
    reg [2:0] rs = 3'b111;                        // run crosses from FCLK0 here
    always @(posedge clk) rs <= {rs[1:0], ~resetn | ~run | ~hp_aresetn};
    wire rst = rs[2];

    reg [25:0] beat = 26'd0;                      // 2^25 / 50 MHz: 0.67 s
    always @(posedge clk) beat <= beat + 26'd1;
    assign led2 = beat[25] & ~rst;

    soc_boot #(.MEMSYS(2), .RAM_WORDS(RAM_WORDS), .BOOTROM_INIT(BOOTROM_INIT),
               .UART_DIV(UART_DIV), .AXI_OFFSET(DDR_BASE), .AXI_DATA_W(64),
               .DIV_ITER(DIV_ITER), .ZB_EXT(ZB_EXT), .BPRED(BPRED),
               .MUL_2C(MUL_2C), .AGU(AGU), .XLATE_2C(XLATE_2C),
               .VALID_FLUSH(VALID_FLUSH), .REG_REDIRECT(REG_REDIRECT),
               .FWD_PRE(FWD_PRE), .IF_PAGE(IF_PAGE), .HPM_LATE(HPM_LATE),
               .CACHE_BRAM(CACHE_BRAM), .I_LINES(I_LINES), .D_LINES(D_LINES)) u_soc (
        .clk(clk), .rst(rst), .uart_rx_pin(uart_rx), .uart_tx_pin(uart_tx),
        .halted(halted), .exit_code(), .warm_reset(),
        .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize), .m_axi_awburst(awburst),
        .m_axi_awcache(awcache), .m_axi_awprot(awprot), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast), .m_axi_wvalid(wvalid),
        .m_axi_wready(wready), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
        .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(arsize), .m_axi_arburst(arburst),
        .m_axi_arcache(arcache), .m_axi_arprot(arprot), .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rlast(rlast), .m_axi_rvalid(rvalid),
        .m_axi_rready(rready));
    assign led = halted;
endmodule

`default_nettype wire
