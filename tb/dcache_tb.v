`timescale 1ns/1ps
`default_nettype none
// Step 43: the D-cache against a reference model. A deliberately tiny cache
// (8 lines x 4 words = 128 bytes) over a 4 KiB region of slow memory, so
// almost every access conflicts: misses, dirty evictions and write-backs
// happen constantly. Half the addresses fall in a 128-byte hot window (hits,
// write hits, dirty lines), half anywhere in 4 KiB. 20000 random reads and byte / halfword / word writes,
// each held until `ready` exactly as the core holds its D-port request, with
// random idle gaps. Every read is checked against a flat-array model; at the
// end every word is checked through cache-or-memory (whichever is newest).
module dcache_tb;
    localparam LW = 4, LINES = 8, WORDS = 1024, N = 20000;
    reg clk=0, rst=1; always #5 clk = ~clk;

    reg  [31:0] addr = 0, wdata = 0; reg req = 0; reg [3:0] we = 0;
    wire [31:0] rdata; wire ready;
    wire m_req, m_we, m_done; wire [31:0] m_addr; wire [32*LW-1:0] m_wdata, m_rdata;

    dcache #(.LINES(LINES), .LINE_WORDS(LW)) dut (
        .clk(clk), .rst(rst), .addr(addr), .req(req), .we(we), .wdata(wdata),
        .rdata(rdata), .ready(ready), .clean(1'b0), .clean_done(),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_done(m_done), .m_rdata(m_rdata));
    mem_slow #(.WORDS(WORDS), .LINE_WORDS(LW), .LATENCY(3)) mem (
        .clk(clk), .rst(rst), .req(m_req), .we(m_we), .burst(1'b1), .addr(m_addr),
        .wmask(4'b1111), .wdata(m_wdata), .done(m_done), .rdata(m_rdata));

    reg [31:0] model [0:WORDS-1];
    integer i, n, fails = 0, reads = 0, writes = 0, cycles = 0, seed = 42;

    always @(posedge clk) if (!rst) cycles = cycles + 1;

    // one access, held until ready; returns the read data
    task access; input [31:0] a; input [3:0] m; input [31:0] d; output [31:0] q;
        begin
            @(negedge clk); addr = a; we = m; wdata = d; req = 1;
            #1; while (!ready) begin @(negedge clk); #1; end
            q = rdata;
            @(posedge clk); #1 req = 0;
        end
    endtask

    // newest value of word wi: the cache if it holds the line, else memory
    function [31:0] newest; input integer wi;
        reg [2:0] li;
        begin
            li = wi[4:2];                       // index = word[4:2] (LW=4, LINES=8)
            if (dut.valid[li] && dut.tags[li] == wi[31:5]) newest = dut.lines[li][32*wi[1:0] +: 32];
            else                                            newest = mem.mem[wi];
        end
    endfunction

    reg [31:0] r, d, q, mk;
    reg [3:0]  m;
    reg [9:0]  w;
    initial begin
        for (i = 0; i < WORDS; i = i + 1) model[i] = 32'd0;
        repeat(3) @(posedge clk); #1 rst = 0;
        for (n = 0; n < N; n = n + 1) begin
            r = $random(seed); d = $random(seed);
            w = r[21] ? {5'b0, r[4:0]} : r[9:0];   // half hot (128 B), half anywhere
            case (r[13:12])
                2'd0, 2'd1: m = 4'b0000;                              // read
                2'd2:       m = r[15] ? (4'b0011 << {r[14], 1'b0})     // halfword
                                      : (4'b0001 << r[15:14]);        // byte
                default:    m = 4'b1111;                              // word
            endcase
            access({20'b0, w, 2'b00}, m, d, q);
            if (m == 0) begin
                reads = reads + 1;
                if (q !== model[w]) begin
                    if (fails < 5) $write("FAIL: read [%h] = %h, model %h\n", {w,2'b0}, q, model[w]);
                    fails = fails + 1;
                end
            end else begin
                writes = writes + 1;
                mk = {{8{m[3]}}, {8{m[2]}}, {8{m[1]}}, {8{m[0]}}};
                model[w] = (model[w] & ~mk) | (d & mk);
            end
            if (r[18:16] == 0) repeat (r[20:19]) @(posedge clk);       // idle gap
        end
        for (i = 0; i < WORDS; i = i + 1)
            if (newest(i) !== model[i]) begin
                if (fails < 10) $write("FAIL: final word %0d = %h, model %h\n", i, newest(i), model[i]);
                fails = fails + 1;
            end
        $write("D-cache unit: %0d reads, %0d writes, %0d misses, %0d writebacks, %0d cycles\n",
               reads, writes, dut.n_miss, dut.n_wb, cycles);
        if (fails == 0) $write("DCACHE: ALL PASS (every read and every final word matches the model)\n");
        else            $write("DCACHE: %0d FAIL\n", fails);
        $finish;
    end
endmodule
`default_nettype wire
