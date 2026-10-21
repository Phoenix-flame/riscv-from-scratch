`timescale 1ns/1ps
`default_nettype none
// Step 43: what the caches buy. sw/cb.hex (cache_bench.c) runs on three SoCs
// built around the SAME cpu_pipe_u:
//   ideal  - soc_pipe_u: Step 42's combinational memories (the upper bound)
//   cached - soc_pipe_c, CACHE_EN=1: 1 KiB I$ + 2 KiB write-back D$, slow memory
//   none   - soc_pipe_c, CACHE_EN=0: the same slow memory, no caches
// Slow memory = LAT cycles to the first word, then one word per cycle.
// Each run's UART output must match tb/cache_bench_expected.txt (produced by
// the host compiler, not by any core); cycles are reported per phase.
module cache_tb;
    parameter LAT = 10;
    reg clk=0, rst=1;
    wire tx_i, tx_c, tx_n, h_i, h_c, h_n;
    always #5 clk = ~clk;

    soc_pipe_u #(.ROM_WORDS(4096), .RAM_WORDS(8192), .CLKS_PER_BIT(4),
                 .IMEM_INIT("sw/cb.hex"), .DMEM_INIT("sw/cb.hex")) ideal (
        .clk(clk), .rst(rst), .uart_tx_pin(tx_i), .halted(h_i));
    soc_pipe_c #(.CACHE_EN(1), .LATENCY(LAT), .ROM_WORDS(4096), .RAM_WORDS(8192), .CLKS_PER_BIT(4),
                 .IMEM_INIT("sw/cb.hex"), .DMEM_INIT("sw/cb.hex")) cached (
        .clk(clk), .rst(rst), .uart_tx_pin(tx_c), .halted(h_c));
    soc_pipe_c #(.CACHE_EN(0), .LATENCY(LAT), .ROM_WORDS(4096), .RAM_WORDS(8192), .CLKS_PER_BIT(4),
                 .IMEM_INIT("sw/cb.hex"), .DMEM_INIT("sw/cb.hex")) none (
        .clk(clk), .rst(rst), .uart_tx_pin(tx_n), .halted(h_n));

    // ---- per-SoC capture: output bytes, cycle stamp at each newline ----
    reg [7:0] ob [0:2][0:1023];
    integer   no [0:2], ph [0:2][0:7], np [0:2], cyc [0:2], ret [0:2];
    integer   s;
    initial for (s = 0; s < 3; s = s + 1) begin no[s]=0; np[s]=0; cyc[s]=0; ret[s]=0; end

    task take; input integer w; input [7:0] c;
        begin
            ob[w][no[w]] = c; no[w] = no[w] + 1;
            if (c == 8'h0A) begin ph[w][np[w]] = cyc[w]; np[w] = np[w] + 1; end
        end
    endtask
    always @(posedge clk) if (!rst) begin
        if (!h_i) begin cyc[0] = cyc[0] + 1; if (ideal.retire)  ret[0] = ret[0] + 1; end
        if (!h_c) begin cyc[1] = cyc[1] + 1; if (cached.retire) ret[1] = ret[1] + 1; end
        if (!h_n) begin cyc[2] = cyc[2] + 1; if (none.retire)   ret[2] = ret[2] + 1; end
        if (ideal.sel_uart  && ideal.wr_any  && ideal.daddr[7:0]==0)  take(0, ideal.dwdata[7:0]);
        if (cached.sel_uart && cached.wr_any && cached.daddr[7:0]==0) take(1, cached.dwdata[7:0]);
        if (none.sel_uart   && none.wr_any   && none.daddr[7:0]==0)   take(2, none.dwdata[7:0]);
    end

    // ---- compare one run with the expected file ----
    integer fails = 0;
    task check; input integer w; input [8*6:1] name;
        integer fd, ch, i, bad;
        begin
            bad = 0;
            fd = $fopen("tb/cache_bench_expected.txt", "r");
            for (i = 0; i < no[w]; i = i + 1) begin
                ch = $fgetc(fd);
                if (ch != ob[w][i]) bad = 1;
            end
            if ($fgetc(fd) != -1) bad = 1;
            $fclose(fd);
            if (bad) begin $write("FAIL[%0s]: UART output differs from the host's\n", name); fails = fails + 1; end
        end
    endtask

    function integer pc; input integer w, k;   // cycles in phase k
        pc = (k == 0) ? ph[w][0] : ph[w][k] - ph[w][k-1];
    endfunction

    integer k;
    initial begin
        repeat(3) @(posedge clk); #1; rst=0;
        while (!(h_i && h_c && h_n) && cyc[2] < 20000000) @(posedge clk);
        #1;
        if (!(h_i && h_c && h_n)) begin $write("FAIL: not all halted\n"); fails = fails + 1; end
        check(0, "ideal"); check(1, "cached"); check(2, "none");

        $write("---- Step 43 cache bench, memory latency %0d cycles ----\n", LAT);
        $write("            reuse      sort    stream     total   CPI\n");
        $write("  ideal  %8d  %8d  %8d  %8d  %0d.%02d\n", pc(0,0), pc(0,1), pc(0,2), cyc[0],
               cyc[0]/ret[0], (cyc[0]*100/ret[0])%100);
        $write("  cached %8d  %8d  %8d  %8d  %0d.%02d\n", pc(1,0), pc(1,1), pc(1,2), cyc[1],
               cyc[1]/ret[1], (cyc[1]*100/ret[1])%100);
        $write("  none   %8d  %8d  %8d  %8d  %0d.%02d\n", pc(2,0), pc(2,1), pc(2,2), cyc[2],
               cyc[2]/ret[2], (cyc[2]*100/ret[2])%100);
        $write("  I$ %0d misses / %0d lookups   D$ %0d misses / %0d lookups, %0d writebacks   speedup %0d.%02dx\n",
               cached.g_cache.u_icache.n_miss, cached.g_cache.u_icache.n_hit + cached.g_cache.u_icache.n_miss,
               cached.g_cache.u_dcache.n_miss, cached.g_cache.u_dcache.n_hit + cached.g_cache.u_dcache.n_miss,
               cached.g_cache.u_dcache.n_wb,
               cyc[2]/cyc[1], (cyc[2]*100/cyc[1])%100);
        if (fails == 0) $write("CACHE (LAT=%0d): ALL PASS\n", LAT);
        else            $write("CACHE (LAT=%0d): %0d FAIL\n", LAT, fails);
        $finish;
    end
endmodule
`default_nettype wire
