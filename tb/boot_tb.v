`timescale 1ns/1ps
`default_nettype none
// =====================================================================
// boot_tb.v  -  the boot platform with a serial cable attached
// ---------------------------------------------------------------------
// soc_boot holds nothing but its boot ROM. This bench is the other end
// of the UART: it decodes everything the machine transmits (echoed, and
// written to +LOG=), and it sends the boot images. +STREAM= is a file of
// chunks, each a 4-byte little-endian length and that many bytes; the
// bench waits for a prompt -- the ROM's "boot> ", or a payload's "type> "
// (Step 50's kdemo reads a line) -- before sending each chunk, so chunk n
// goes to the n-th prompt (tools/rvboot builds the stream).
//
// Runs until the test device powers the machine off (or fails it), then
// writes the DTB the ROM left at the top of RAM to +DTB= so that dtc can
// check it, and prints a one-line summary for tools/rvboot to parse.
// Runs under Icarus and under Verilator (--binary --timing).
//
// MEMSYS picks soc_boot's memory system (Step 51): 0 ideal, 1 caches +
// block RAM, 2 caches + DDR over AXI4 -- for which this bench supplies
// the DDR: axi4_mem, RAM_WORDS deep, with DDR-like latency and stalls --
// AXI_DATA_W bits wide: 64 is a Zynq S_AXI_HP port (Step 54).
//
// For a Linux shell (Step 53, tools/rvlinux), all off by default:
//   +PROMPT=s     one more prompt to send a chunk at (the shell's "rvfs# ")
//   +TYPEGAP=n    wait n cycles after each byte of a short chunk (< 256
//                 bytes: typed input), as a person would -- a shell that
//                 echoes every key cannot keep up with a line at full rate
//   +PRELOAD=f    $readmemh f into RAM before the ROM runs (word addresses
//                 from RAM_BASE). A test shortcut, not a boot path: the ROM
//                 still receives, checks and enters an image -- a short one.
// =====================================================================
module boot_tb;
    parameter MEMSYS    = 0;
    parameter RAM_WORDS = 65536;          // 256 KiB (the ROM finds the size itself)
    parameter DIVISOR   = 1;              // platform.h UART_DIVISOR
    parameter AXI_DATA_W = 32;            // MEMSYS 2: 32, or 64 (S_AXI_HP)
    parameter DIV_ITER   = 0;             // the 32-cycle divider (the Linux board build uses it)
    parameter ZB_EXT     = 1;             // the Linux board build: 0 (no Zba/Zbb/Zbc/Zbs)
    parameter BPRED      = 1;             //                        0 (no branch predictor)
    parameter MUL_2C     = 0;             //                        1 (registered multiplies)
    parameter AGU        = 0;             //                        1 (an address adder)
    parameter XLATE_2C   = 0;             //                        1 (registered D-TLB lookup)
    parameter VALID_FLUSH = 0;            //                        1 (flush clears valid bits)
    parameter REG_REDIRECT = 0;           //                        1 (registered branch redirect)
    localparam [31:0] DDR_BASE = 32'h1000_0000;     // where RAM sits on the AXI side
    localparam CPB = 16 * DIVISOR;        // clocks per bit

    reg clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    reg  rx = 1'b1;
    wire tx, halted, warm_reset;
    wire [15:0] exit_code;

    wire [31:0] awaddr, araddr;
    wire [AXI_DATA_W-1:0]   wdata, rdata;
    wire [AXI_DATA_W/8-1:0] wstrb;
    wire [7:0]  awlen, arlen;
    wire [2:0]  awsize, arsize;
    wire [1:0]  awburst, arburst, bresp, rresp;
    wire        awvalid, awready, wlast, wvalid, wready, bvalid, bready,
                arvalid, arready, rlast, rvalid, rready;

    soc_boot #(.RAM_WORDS(RAM_WORDS), .MEMSYS(MEMSYS), .AXI_OFFSET(DDR_BASE),
               .AXI_DATA_W(AXI_DATA_W), .DIV_ITER(DIV_ITER),
               .ZB_EXT(ZB_EXT), .BPRED(BPRED), .MUL_2C(MUL_2C), .AGU(AGU),
               .XLATE_2C(XLATE_2C), .VALID_FLUSH(VALID_FLUSH),
               .REG_REDIRECT(REG_REDIRECT)) dut (
        .clk(clk), .rst(rst), .uart_rx_pin(rx), .uart_tx_pin(tx),
        .halted(halted), .exit_code(exit_code), .warm_reset(warm_reset),
        .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize), .m_axi_awburst(awburst),
        .m_axi_awcache(), .m_axi_awprot(), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast), .m_axi_wvalid(wvalid),
        .m_axi_wready(wready), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
        .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(arsize), .m_axi_arburst(arburst),
        .m_axi_arcache(), .m_axi_arprot(), .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rlast(rlast), .m_axi_rvalid(rvalid),
        .m_axi_rready(rready));

    // the DTB the ROM left in the last 8 KiB of RAM, wherever the RAM is
    reg  dump_req = 1'b0;
    reg  [8*256-1:0] dtbf, preloadf;
    integer dfd, w;
    reg [31:0] word;
    generate if (MEMSYS == 2) begin : g_ddr
        axi4_mem #(.WORDS(RAM_WORDS), .BASE(DDR_BASE), .LATENCY(20), .STALL(1),
                   .DATA_W(AXI_DATA_W)) u_ddr (
            .clk(clk), .rst(rst),
            .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst), .awvalid(awvalid),
            .awready(awready), .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid),
            .wready(wready), .bresp(bresp), .bvalid(bvalid), .bready(bready),
            .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst), .arvalid(arvalid),
            .arready(arready), .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid),
            .rready(rready));
        initial if ($value$plusargs("PRELOAD=%s", preloadf)) begin
            #1 $readmemh(preloadf, u_ddr.mem);
        end
        always @(posedge dump_req) begin
            dfd = $fopen(dtbf, "wb");
            for (w = RAM_WORDS - 2048; w < RAM_WORDS; w = w + 1) begin
                word = u_ddr.mem[w];
                $fwrite(dfd, "%c%c%c%c", word[7:0], word[15:8], word[23:16], word[31:24]);
            end
            $fclose(dfd);
            if (u_ddr.errors != 0) $display("BOOT-TB: AXI protocol errors: %0d", u_ddr.errors);
        end
    end else begin : g_local
        assign awready = 1'b0; assign wready = 1'b0; assign bvalid = 1'b0; assign bresp = 2'b00;
        assign arready = 1'b0; assign rvalid = 1'b0; assign rlast = 1'b0; assign rresp = 2'b00;
        assign rdata = {AXI_DATA_W{1'b0}};
        initial if ($value$plusargs("PRELOAD=%s", preloadf)) begin
            #1 $readmemh(preloadf, dut.ram);
        end
        always @(posedge dump_req) begin
            dfd = $fopen(dtbf, "wb");
            for (w = RAM_WORDS - 2048; w < RAM_WORDS; w = w + 1) begin
                word = dut.ram[w];
                $fwrite(dfd, "%c%c%c%c", word[7:0], word[15:8], word[23:16], word[31:24]);
            end
            $fclose(dfd);
        end
    end endgenerate

    reg [8*256-1:0] romf, streamf, logf;
    integer cyc = 0, maxcyc = 40000000, resets = 0, logfd = 0;
    always @(posedge clk) if (!rst) cyc <= cyc + 1;
    reg wr_q = 1'b0;
    always @(posedge clk) begin
        wr_q <= warm_reset;
        if (warm_reset && !wr_q) resets <= resets + 1;
    end

    // what FENCE.I costs: how many there were, and the cycles they waited
    // in EX for the caches (always 0 on ideal memory)
    integer n_fencei = 0, fencei_wait = 0;
    reg     fi_q = 1'b0;
    always @(posedge clk) if (!rst) begin
        fi_q <= dut.fencei_req;
        if (dut.fencei_req && !fi_q) n_fencei <= n_fencei + 1;
        if (dut.fencei_req && !dut.fencei_ack) fencei_wait <= fencei_wait + 1;
    end

    // how close the ROM comes to losing bytes: the RX FIFO's high-water mark
    integer rx_peak = 0;
    always @(posedge clk) if (!rst && dut.u_uart.rx_n > rx_peak) rx_peak <= dut.u_uart.rx_n;

    // ---- receive: decode the TX line (8N1) ----
    reg [47:0] last6 = 48'd0;             // the last six characters seen
    reg [47:0] prompt_x = 48'd0, prompt_m = 48'd0;   // +PROMPT, and its byte mask
    integer prompts = 0, nrx = 0;
    reg [7:0] ch;
    integer i;
    initial begin
        forever begin
            @(negedge tx);
            repeat (CPB / 2) @(posedge clk);
            if (tx == 1'b0) begin
                for (i = 0; i < 8; i = i + 1) begin
                    repeat (CPB) @(posedge clk);
                    ch[i] = tx;
                end
                repeat (CPB) @(posedge clk);           // stop bit
                if (ch != 8'h0d) $write("%c", ch);
                if (logfd != 0) begin $fwrite(logfd, "%c", ch); $fflush(logfd); end
                nrx = nrx + 1;
                last6 = {last6[39:0], ch};
                if (last6 == "boot> " || last6 == "type> " ||
                    (prompt_m != 0 && (last6 & prompt_m) == prompt_x)) begin
                    prompts = prompts + 1;
                    $display("\nBOOT-TB prompt %0d at cycle %0d", prompts, cyc);
                end
            end
        end
    end

    // ---- send: one chunk per prompt ----
    task send_byte; input [7:0] b; integer k; begin
        rx = 1'b0; repeat (CPB) @(posedge clk);
        for (k = 0; k < 8; k = k + 1) begin rx = b[k]; repeat (CPB) @(posedge clk); end
        rx = 1'b1; repeat (CPB) @(posedge clk);
    end endtask

    integer sfd, len, n, c, chunk = 0, sent = 0, typegap = 0;
    initial begin
        if (!$value$plusargs("ROM=%s", romf)) begin $display("boot_tb: need +ROM="); $finish; end
        $readmemh(romf, dut.rom);
        if ($value$plusargs("MAXCYC=%d", maxcyc)) ;
        if ($value$plusargs("LOG=%s", logf)) logfd = $fopen(logf, "w");
        if ($value$plusargs("TYPEGAP=%d", typegap)) ;
        if ($value$plusargs("PROMPT=%s", prompt_x))
            for (n = 0; n < 6; n = n + 1) if (prompt_x[8*n +: 8] != 8'd0) prompt_m[8*n +: 8] = 8'hff;
        sfd = 0;
        if ($value$plusargs("STREAM=%s", streamf)) sfd = $fopen(streamf, "rb");
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;
        if (sfd != 0) begin
            c = $fgetc(sfd);
            while (c != -1) begin
                len = c;
                len = len | ($fgetc(sfd) << 8);
                len = len | ($fgetc(sfd) << 16);
                len = len | ($fgetc(sfd) << 24);
                while (prompts <= chunk) @(posedge clk);
                repeat (4 * CPB) @(posedge clk);
                for (n = 0; n < len; n = n + 1) begin
                    send_byte($fgetc(sfd));
                    if (len < 256 && typegap > 0) repeat (typegap) @(posedge clk);
                end
                sent = sent + len;
                chunk = chunk + 1;
                c = $fgetc(sfd);
            end
            $fclose(sfd);
        end
    end

    // ---- finish ----
    initial begin
        while (halted !== 1'b1 && cyc < maxcyc) @(posedge clk);
        repeat (4 * CPB) @(posedge clk);
        if (logfd != 0) $fclose(logfd);
        if ($value$plusargs("DTB=%s", dtbf)) begin
            dump_req = 1'b1;
            @(posedge clk);
        end
        $display("");
        $display("BOOT-TB fence.i: %0d, %0d cycles waiting for the caches", n_fencei, fencei_wait);
        $display("BOOT-TB: %0s exit=%0d cycles=%0d resets=%0d chunks=%0d sent=%0d received=%0d rxfifo_peak=%0d",
                 halted ? "halted" : "TIMEOUT", exit_code, cyc, resets, chunk, sent, nrx, rx_peak);
        $finish;
    end
endmodule
`default_nettype wire
