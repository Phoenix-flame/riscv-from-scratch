`timescale 1ns/1ps
`default_nettype none
// =====================================================================
// axi4_line_tb.v  -  cache lines over AXI4 bursts, against a stalling slave
// ---------------------------------------------------------------------
// axi4_line_master against axi4_mem with LATENCY cycles to the first beat
// and pseudo-random gaps on all five channels. Writes random lines to
// random line addresses (the master relocates 0x8000_0000 to the slave's
// window at 0x1000_0000), reads every one back and compares, overwrites
// some and checks again; then reads outside the window and checks that
// the SLVERR comes back as `err`. The slave counts protocol errors
// (WLAST placement, burst type, size); there must be none.
// =====================================================================
module axi4_line_tb;
    localparam LW = 8, W = 32 * LW, N = 64;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg          req = 0, we = 0;
    reg  [31:0]  addr = 0;
    reg  [W-1:0] wdata = 0;
    wire         done, err;
    wire [W-1:0] rdata;

    wire [31:0] awaddr, wd, araddr, rd;
    wire [7:0]  awlen, arlen;
    wire [2:0]  awsize, arsize, awprot, arprot;
    wire [1:0]  awburst, arburst, bresp, rresp;
    wire [3:0]  awcache, arcache, wstrb;
    wire        awvalid, awready, wlast, wvalid, wready, bvalid, bready,
                arvalid, arready, rlast, rvalid, rready;

    axi4_line_master #(.LINE_WORDS(LW), .ADDR_OFFSET(32'h9000_0000)) dut (
        .clk(clk), .rst(rst), .req(req), .we(we), .addr(addr), .wdata(wdata),
        .done(done), .rdata(rdata), .err(err),
        .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize), .m_axi_awburst(awburst),
        .m_axi_awcache(awcache), .m_axi_awprot(awprot), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wd), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast), .m_axi_wvalid(wvalid),
        .m_axi_wready(wready), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
        .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(arsize), .m_axi_arburst(arburst),
        .m_axi_arcache(arcache), .m_axi_arprot(arprot), .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_rdata(rd), .m_axi_rresp(rresp), .m_axi_rlast(rlast), .m_axi_rvalid(rvalid),
        .m_axi_rready(rready));
    axi4_mem #(.WORDS(1 << 16), .BASE(32'h1000_0000), .LATENCY(7), .STALL(1)) mem (
        .clk(clk), .rst(rst),
        .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst), .awvalid(awvalid),
        .awready(awready), .wdata(wd), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid),
        .wready(wready), .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst), .arvalid(arvalid),
        .arready(arready), .rdata(rd), .rresp(rresp), .rlast(rlast), .rvalid(rvalid),
        .rready(rready));

    // AXI's rule: once valid is up it stays up, with stable payload, until ready
    reg aw_q = 0, w_q = 0, ar_q = 0; reg [31:0] awaddr_q, araddr_q, wd_q;
    integer viol = 0;
    always @(posedge clk) if (!rst) begin
        if (aw_q && !awvalid) viol = viol + 1;
        if (ar_q && !arvalid) viol = viol + 1;
        if (w_q  && (!wvalid || wd != wd_q)) viol = viol + 1;
        if (aw_q && awaddr != awaddr_q) viol = viol + 1;
        aw_q <= awvalid & ~awready; ar_q <= arvalid & ~arready; w_q <= wvalid & ~wready;
        awaddr_q <= awaddr; araddr_q <= araddr; wd_q <= wd;
    end

    task xfer; input w; input [31:0] a; input [W-1:0] d; integer g; begin
        @(negedge clk); req = 1; we = w; addr = a; wdata = d;
        g = 0; while (!done && g < 10000) begin @(posedge clk); #1; g = g + 1; end
        @(negedge clk); req = 0;
    end endtask

    reg [W-1:0] model [0:N-1];
    reg [31:0]  la    [0:N-1];
    integer i, j, fails = 0, cyc0, cyc1;
    reg [W-1:0] r;
    initial begin
        repeat (3) @(posedge clk); #1 rst = 0;
        for (i = 0; i < N; i = i + 1) begin
            la[i] = 32'h8000_0000 + ((i * 37 % 2048) << 5);           // distinct lines
            for (j = 0; j < LW; j = j + 1) r[32*j +: 32] = $random;
            model[i] = r;
        end
        cyc0 = $time;
        for (i = 0; i < N; i = i + 1) xfer(1, la[i], model[i]);
        for (i = 0; i < N; i = i + 1) begin
            xfer(0, la[i], 0);
            if (rdata !== model[i]) fails = fails + 1;
        end
        cyc1 = $time;
        for (i = 0; i < N; i = i + 4) begin                          // overwrite a quarter
            for (j = 0; j < LW; j = j + 1) r[32*j +: 32] = $random;
            model[i] = r; xfer(1, la[i], r);
        end
        for (i = 0; i < N; i = i + 1) begin
            xfer(0, la[i], 0);
            if (rdata !== model[i]) fails = fails + 1;
        end
        $display("  %0d lines written, read back, a quarter rewritten, read again: %0d mismatches",
                 N, fails);
        $display("  %0d writes + %0d reads in %0d cycles (%0d per line, latency 7, stalls on)",
                 N, N, (cyc1 - cyc0) / 10, (cyc1 - cyc0) / 10 / (2 * N));
        if (err) fails = fails + 1;
        xfer(0, 32'h8000_0000 + 32'h0010_0000, 0);                    // past the 256 KiB window
        $display("  read outside the window -> err %0d", err);
        if (!err) fails = fails + 1;
        $display("  slave protocol errors %0d, valid-dropped-before-ready %0d", mem.errors, viol);
        fails = fails + mem.errors + viol;
        if (fails == 0) $display("AXI4-LINE: ALL PASS");
        else            $display("AXI4-LINE: %0d FAIL", fails);
        $finish;
    end
endmodule
`default_nettype wire
