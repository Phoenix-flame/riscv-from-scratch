`timescale 1ns/1ps
`default_nettype none
// Step 59: dcache_b (block-RAM arrays, a registered read at a hinted
// address) against the same reference model as dcache_tb: a tiny cache
// (8 lines x 4 words) over 4 KiB of slow memory, so misses, dirty
// evictions and write-backs happen constantly. 20000 random reads and
// byte / halfword / word writes, each held until `ready`, with random
// idle gaps. Each access's hint is, at random, the next access's address
// (as the core gives it), this access's, or a random one. `hint_ok` is
// what the core promises: up only when the next cycle's request, if any,
// really is at the hint -- the next access's once this one is done, this
// one's while it waits, never a random one. A hint may only change how
// many cycles an access takes. Every 400 accesses `clean`
// runs, and then all of memory must equal the model. At the end every
// word is checked through cache-or-memory.
module dcache_b_tb;
    localparam LW = 4, LINES = 8, WORDS = 1024, N = 20000;
    reg clk=0, rst=1; always #5 clk = ~clk;

    reg  [31:0] addr = 0, wdata = 0, hint = 0; reg req = 0; reg [3:0] we = 0; reg clean = 0;
    reg  [1:0]  hmode = 2'd3;
    wire [31:0] rdata; wire ready, clean_done;
    wire        hint_ok = (hmode == 2'd0 || hmode == 2'd1) ? (!req || ready) :
                          (hmode == 2'd2)                  ? (req && !ready) : 1'b0;
    wire m_req, m_we, m_done; wire [31:0] m_addr; wire [32*LW-1:0] m_wdata, m_rdata;

    dcache_b #(.LINES(LINES), .LINE_WORDS(LW)) dut (
        .clk(clk), .rst(rst), .addr(addr), .req(req), .we(we), .wdata(wdata),
        .rdata(rdata), .ready(ready), .hint(hint), .hint_ok(hint_ok), .clean(clean), .clean_done(clean_done),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_done(m_done), .m_rdata(m_rdata));
    mem_slow #(.WORDS(WORDS), .LINE_WORDS(LW), .LATENCY(3)) mem (
        .clk(clk), .rst(rst), .req(m_req), .we(m_we), .burst(1'b1), .addr(m_addr),
        .wmask(4'b1111), .wdata(m_wdata), .done(m_done), .rdata(m_rdata));

    reg [31:0] model [0:WORDS-1];
    reg [9:0]  aw [0:N];                         // the access sequence, made in advance
    reg [3:0]  am [0:N];
    reg [31:0] ad [0:N];
    reg [2:0]  agap [0:N];
    reg [1:0]  ahint [0:N];
    integer i, n, fails = 0, reads = 0, writes = 0, cycles = 0, seed = 59, cleans = 0;
    integer accs = 0, acc_cycles = 0;

    always @(posedge clk) if (!rst) cycles = cycles + 1;

    task access; input integer k; output [31:0] q;
        integer t;
        begin
            @(negedge clk); addr = {20'b0, aw[k], 2'b00}; we = am[k]; wdata = ad[k]; req = 1;
            hmode = ahint[k];
            case (ahint[k])
                2'd0, 2'd1: hint = {20'b0, aw[k+1], 2'b00};          // as the core: the next one
                2'd2:       hint = addr;
                default:    hint = $random(seed);
            endcase
            t = 0;
            #1; while (!ready) begin @(negedge clk); t = t + 1; #1; end
            q = rdata; accs = accs + 1; acc_cycles = acc_cycles + t + 1;
            @(posedge clk); #1 req = 0;
        end
    endtask

    function [31:0] newest; input integer wi;
        reg [2:0] li;
        begin
            li = wi[4:2];
            // {valid, dirty, tag} entries: valid is bit 26 (TAG = 25 here)
            if (dut.tags[li][26] && dut.tags[li][24:0] == wi[29:5]) newest = dut.lines[li][32*wi[1:0] +: 32];
            else                                            newest = mem.mem[wi];
        end
    endfunction

    reg [31:0] r, q, mk;
    initial begin
        for (i = 0; i < WORDS; i = i + 1) model[i] = 32'd0;
        for (n = 0; n <= N; n = n + 1) begin
            r = $random(seed);
            aw[n] = r[21] ? {5'b0, r[4:0]} : r[9:0];
            case (r[13:12])
                2'd0, 2'd1: am[n] = 4'b0000;
                2'd2:       am[n] = r[15] ? (4'b0011 << {r[14], 1'b0}) : (4'b0001 << r[15:14]);
                default:    am[n] = 4'b1111;
            endcase
            ad[n] = $random(seed);
            agap[n] = (r[18:16] == 0) ? {1'b0, r[20:19]} : 3'd0;
            ahint[n] = r[23:22];
        end
        repeat(3) @(posedge clk); #1 rst = 0;
        for (n = 0; n < N; n = n + 1) begin
            access(n, q);
            if (am[n] == 0) begin
                reads = reads + 1;
                if (q !== model[aw[n]]) begin
                    if (fails < 5) $write("FAIL: read [%h] = %h, model %h (access %0d)\n", {aw[n],2'b0}, q, model[aw[n]], n);
                    fails = fails + 1;
                end
            end else begin
                writes = writes + 1;
                mk = {{8{am[n][3]}}, {8{am[n][2]}}, {8{am[n][1]}}, {8{am[n][0]}}};
                model[aw[n]] = (model[aw[n]] & ~mk) | (ad[n] & mk);
            end
            if (agap[n] != 0) repeat (agap[n]) @(posedge clk);
            if (n % 400 == 399) begin                               // FENCE.I's write-back
                @(negedge clk); clean = 1;
                while (!clean_done) @(negedge clk);
                clean = 0; cleans = cleans + 1;
                for (i = 0; i < WORDS; i = i + 1)
                    if (mem.mem[i] !== model[i]) begin
                        if (fails < 10) $write("FAIL: after clean %0d, memory word %0d = %h, model %h\n",
                                               cleans, i, mem.mem[i], model[i]);
                        fails = fails + 1;
                    end
            end
        end
        for (i = 0; i < WORDS; i = i + 1)
            if (newest(i) !== model[i]) begin
                if (fails < 10) $write("FAIL: final word %0d = %h, model %h\n", i, newest(i), model[i]);
                fails = fails + 1;
            end
        $write("D-cache (block RAM) unit: %0d reads, %0d writes, %0d misses, %0d writebacks, %0d cleans, %0d cycles, %0d.%02d cycles an access\n",
               reads, writes, dut.n_miss, dut.n_wb, cleans, cycles, acc_cycles / accs, (100 * acc_cycles / accs) % 100);
        if (fails == 0) $write("DCACHE-B: ALL PASS (every read, every word after each clean, and every final word match the model)\n");
        else            $write("DCACHE-B: %0d FAIL\n", fails);
        $finish;
    end
endmodule
`default_nettype wire
