`timescale 1ns/1ps
`default_nettype none
// Directed test of the bus->AXI4-Lite master against the wait-state slave.
// Drives the core-side request the way cpu_mc_stall does (hold req until the
// ready pulse), checks write/read round-trips, and confirms the transaction
// actually takes multiple cycles (the latency the slave injects) -- i.e. the
// ready handshake, not a fixed pipe, is what completes the access.
module axi_lite_tb;
    reg clk=0, rst=1; always #5 clk=~clk;

    reg         req=0, we=0;
    reg  [31:0] addr=0, wdata=0;
    reg  [3:0]  wstrb=4'hF;
    wire [31:0] rdata;
    wire        ready;

    wire [31:0] awaddr, wd, araddr;
    wire [2:0]  awprot, arprot;
    wire [3:0]  ws;
    wire        awvalid, awready, wvalid, wready, bvalid, bready;
    wire [1:0]  bresp, rresp;
    wire        arvalid, arready, rvalid, rready;
    wire [31:0] rd;

    axi_lite_master dut (
        .clk(clk), .rst(rst), .req(req), .we(we), .addr(addr),
        .wdata(wdata), .wstrb(wstrb), .rdata(rdata), .ready(ready),
        .m_awaddr(awaddr), .m_awprot(awprot), .m_awvalid(awvalid), .m_awready(awready),
        .m_wdata(wd), .m_wstrb(ws), .m_wvalid(wvalid), .m_wready(wready),
        .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready),
        .m_araddr(araddr), .m_arprot(arprot), .m_arvalid(arvalid), .m_arready(arready),
        .m_rdata(rd), .m_rresp(rresp), .m_rvalid(rvalid), .m_rready(rready)
    );
    axi_lite_slave_mem #(.WORDS(256), .AW_WAIT(2), .B_WAIT(3), .R_WAIT(4)) slv (
        .clk(clk), .rst(rst),
        .s_awaddr(awaddr), .s_awprot(awprot), .s_awvalid(awvalid), .s_awready(awready),
        .s_wdata(wd), .s_wstrb(ws), .s_wvalid(wvalid), .s_wready(wready),
        .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
        .s_araddr(araddr), .s_arprot(arprot), .s_arvalid(arvalid), .s_arready(arready),
        .s_rdata(rd), .s_rresp(rresp), .s_rvalid(rvalid), .s_rready(rready)
    );

    integer cyc, fails;
    integer t0, lat;

    task axi_write(input [31:0] a, input [31:0] d);
        begin
            @(negedge clk); req=1; we=1; addr=a; wdata=d; wstrb=4'hF;
            while (!ready) @(negedge clk);
            @(negedge clk); req=0; we=0;
        end
    endtask
    task axi_read(input [31:0] a, output [31:0] d);
        begin
            @(negedge clk); req=1; we=0; addr=a;
            t0=cyc;
            while (!ready) @(negedge clk);
            lat = cyc - t0;
            d = rdata;
            @(negedge clk); req=0;
        end
    endtask

    reg [31:0] got;
    initial begin
        cyc=0; fails=0;
        repeat(3) @(posedge clk); #1; rst=0;

        axi_write(32'h40000000, 32'hCAFEBABE);
        axi_write(32'h40000004, 32'h12345678);
        axi_write(32'h40000010, 32'hA5A5_0F0F);

        axi_read(32'h40000000, got);
        if (got!==32'hCAFEBABE) begin fails=fails+1; $display("FAIL rd0 got %h",got); end
        if (lat < 5) begin fails=fails+1; $display("FAIL latency too low (%0d) - not really stalling", lat); end
        else $display("read round-trip latency = %0d cycles (variable-latency slave)", lat);
        axi_read(32'h40000004, got);
        if (got!==32'h12345678) begin fails=fails+1; $display("FAIL rd4 got %h",got); end
        axi_read(32'h40000010, got);
        if (got!==32'hA5A50F0F) begin fails=fails+1; $display("FAIL rd10 got %h",got); end

        $display("");
        if (fails==0) $display("AXI-LITE: ALL PASS");
        else          $display("AXI-LITE: %0d FAIL", fails);
        $finish;
    end
    always @(posedge clk) cyc=cyc+1;
endmodule
`default_nettype wire
