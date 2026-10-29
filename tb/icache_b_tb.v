`timescale 1ns/1ps
`default_nettype none
// Step 59: icache_b (block-RAM arrays, read a cycle ahead at a hinted
// address) against memory: a tiny cache (8 lines x 4 words) over 4 KiB,
// 30000 fetches -- runs of sequential ones, as code, and random jumps --
// each held until `ready`. The hint is, at random, the next fetch's
// address (what the core gives), this one's, or a random one. Now and
// then `inval` (FENCE.I) lands, some of them during a fill. Every fetch
// must return memory's word.
module icache_b_tb;
    localparam LW = 4, LINES = 8, WORDS = 1024, N = 30000;
    reg clk=0, rst=1; always #5 clk = ~clk;

    reg  [31:0] addr = 0, hint = 0; reg req = 0, inval = 0;
    wire [31:0] rdata; wire ready;
    wire m_req, m_done; wire [31:0] m_addr; wire [32*LW-1:0] m_rdata;

    icache_b #(.LINES(LINES), .LINE_WORDS(LW)) dut (
        .clk(clk), .rst(rst), .addr(addr), .req(req), .rdata(rdata), .ready(ready),
        .hint(hint), .inval(inval),
        .m_req(m_req), .m_addr(m_addr), .m_done(m_done), .m_rdata(m_rdata));
    mem_slow #(.WORDS(WORDS), .LINE_WORDS(LW), .LATENCY(3)) mem (
        .clk(clk), .rst(rst), .req(m_req), .we(1'b0), .burst(1'b1), .addr(m_addr),
        .wmask(4'b0000), .wdata({32*LW{1'b0}}), .done(m_done), .rdata(m_rdata));

    reg [9:0] seq [0:N];
    integer i, n, fails = 0, seed = 7, accs = 0, acc_cycles = 0, invals = 0, t;
    reg [31:0] r;
    reg [9:0]  w;

    // a FENCE.I now and then, at any cycle (inside fills too)
    always @(negedge clk) if (!rst) begin
        r = $random(seed);
        inval = (r[9:0] == 0);
        if (inval) invals = invals + 1;
    end

    initial begin
        for (i = 0; i < WORDS; i = i + 1) mem.mem[i] = $random(seed);
        w = 0;
        for (n = 0; n <= N; n = n + 1) begin
            r = $random(seed);
            w = (r[3:0] == 0) ? r[13:4] : w + 1'b1;         // mostly sequential, sometimes a jump
            seq[n] = w;
        end
        repeat(3) @(posedge clk); #1 rst = 0;
        for (n = 0; n < N; n = n + 1) begin
            @(negedge clk); #1 addr = {20'b0, seq[n], 2'b00}; req = 1;
            r = $random(seed);
            case (r[1:0])
                2'd0, 2'd1: hint = {20'b0, seq[n+1], 2'b00};
                2'd2:       hint = addr;
                default:    hint = $random(seed);
            endcase
            t = 0;
            #1; while (!ready) begin @(negedge clk); #2; t = t + 1; end
            accs = accs + 1; acc_cycles = acc_cycles + t + 1;
            if (rdata !== mem.mem[seq[n]]) begin
                if (fails < 5) $write("FAIL: fetch [%h] = %h, memory %h\n", addr, rdata, mem.mem[seq[n]]);
                fails = fails + 1;
            end
            @(posedge clk); #1 req = 0;
        end
        $write("I-cache (block RAM) unit: %0d fetches, %0d misses, %0d invalidations, %0d.%02d cycles a fetch\n",
               N, dut.n_miss, invals, acc_cycles / accs, (100 * acc_cycles / accs) % 100);
        if (fails == 0) $write("ICACHE-B: ALL PASS (every fetch matches memory)\n");
        else            $write("ICACHE-B: %0d FAIL\n", fails);
        $finish;
    end
endmodule
`default_nettype wire
