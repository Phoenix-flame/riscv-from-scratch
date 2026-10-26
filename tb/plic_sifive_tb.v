`timescale 1ns/1ps
`default_nettype none
// =====================================================================
// plic_sifive_tb.v  -  the standard-layout PLIC, context by context
// ---------------------------------------------------------------------
// Two contexts (0 = M, 1 = S) over 31 sources, driven through the
// register map a kernel's driver uses: priorities, per-context enables
// and thresholds, claim / complete, and the gateway's rules -- a claimed
// source cannot interrupt again until completed, a level source still
// asserted re-pends after the complete, and a pulse is remembered.
// =====================================================================
module plic_sifive_tb;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg         sel = 0, we = 0;
    reg  [25:0] addr = 0;
    reg  [31:0] wdata = 0;
    wire [31:0] rdata;
    reg  [31:1] src = 0;
    wire [1:0]  eip;

    plic_sifive #(.SOURCES(31), .CONTEXTS(2)) dut (
        .clk(clk), .rst(rst), .sel(sel), .we(we), .addr(addr), .wdata(wdata),
        .rdata(rdata), .src(src), .eip(eip));

    integer fails = 0;
    task wr; input [25:0] a; input [31:0] v; begin
        @(negedge clk); sel = 1; we = 1; addr = a; wdata = v;
        @(negedge clk); sel = 0; we = 0;
    end endtask
    reg [31:0] rv;
    task rd; input [25:0] a; begin                   // one-cycle load, as the core makes
        @(negedge clk); sel = 1; we = 0; addr = a; #1 rv = rdata;
        @(negedge clk); sel = 0;
    end endtask
    task check; input c; input [8*56-1:0] what; begin
        if (!c) begin $display("  FAIL %0s", what); fails = fails + 1; end
        else         $display("  ok   %0s", what);
    end endtask

    localparam PRIO = 26'h0, PEND = 26'h1000, EN0 = 26'h2000, EN1 = 26'h2080,
               TH0 = 26'h200000, CL0 = 26'h200004, TH1 = 26'h201000, CL1 = 26'h201004;

    initial begin
        repeat (3) @(posedge clk); #1 rst = 0;

        wr(PRIO + 4*10, 3);  wr(PRIO + 4*3, 5);  wr(PRIO + 4*7, 3);
        rd(PRIO + 4*3);       check(rv == 5, "priority 3 reads back");
        rd(PRIO + 4*0);       check(rv == 0, "source 0 does not exist");
        src[10] = 1;
        @(negedge clk);
        rd(PEND);             check(rv == (1 << 10), "source 10 pending");
        check(eip == 2'b00,   "pending but enabled nowhere: no interrupt");
        wr(EN1, 1 << 10);
        @(negedge clk);
        check(eip == 2'b10,   "enabled for context 1 (S): SEIP only");
        rd(EN1);              check(rv == (1 << 10), "context 1 enable reads back");
        wr(TH1, 3);
        @(negedge clk);
        check(eip == 2'b00,   "threshold 3 masks priority 3");
        wr(TH1, 2);
        @(negedge clk);
        check(eip == 2'b10,   "threshold 2 lets it through");

        rd(CL1);              check(rv == 10, "context 1 claims 10");
        check(eip == 2'b00,   "claimed: no longer pending");
        rd(CL1);              check(rv == 0, "nothing else to claim");
        wr(CL1, 10);          // complete while the level is still high
        @(negedge clk);
        check(eip == 2'b10,   "still asserted after complete: pends again");
        src[10] = 0;
        rd(CL1);              check(rv == 10, "claimed again");
        wr(CL1, 10);
        @(negedge clk);
        check(eip == 2'b00,   "deasserted + completed: quiet");

        // priority order and ties, both contexts
        wr(EN0, (1 << 3) | (1 << 7)); wr(EN1, (1 << 3) | (1 << 7) | (1 << 10));
        wr(TH1, 0);
        src[7] = 1; src[3] = 1; src[10] = 1;
        @(negedge clk);
        src[7] = 0; src[3] = 0;                       // pulses: remembered as pending
        @(negedge clk);
        check(eip == 2'b11,   "both contexts see work");
        rd(CL0);              check(rv == 3, "context 0 takes the highest priority (3: prio 5)");
        rd(CL1);              check(rv == 7, "context 1 next: 7 beats 10 at equal priority (lower ID)");
        rd(CL0);              check(rv == 0, "context 0: 10 is not enabled for it");
        rd(CL1);              check(rv == 10, "context 1 gets 10");
        rd(PEND);             check(rv == 0, "all claimed");
        wr(CL0, 3); wr(CL1, 7);
        src[10] = 0; wr(CL1, 10);
        @(negedge clk);
        check(eip == 2'b00,   "all completed, nothing asserted");

        if (fails == 0) $display("PLIC-SIFIVE: ALL PASS");
        else            $display("PLIC-SIFIVE: %0d FAIL", fails);
        $finish;
    end
endmodule
`default_nettype wire
