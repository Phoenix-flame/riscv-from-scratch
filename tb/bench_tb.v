`timescale 1ns/1ps
`default_nettype none
// Step 48: run one benchmark image (Dhrystone or CoreMark) on the unified
// pipeline and echo its UART. The program times itself with the cycle and
// instret counters and prints its own result; this bench only loads it,
// runs it to the SYSCON halt and prints the totals it counted itself.
//
//   default    soc_pipe_u: ideal single-cycle memory (the core's own speed)
//   -DCACHED   soc_pipe_c: I/D caches in front of slow memory (LAT cycles)
//
//   iverilog -Pbench_tb.BPRED=0 ...       predictor off
//   iverilog -DCACHED -Pbench_tb.LAT=20 -Pbench_tb.I_LINES=32 ...
//   vvp bench.vvp +IMG=build/bench/dhry_O2.hex [+MAXCYC=N]
module bench_tb;
    parameter BPRED   = 1;
    parameter LAT     = 10;
    parameter I_LINES = 64;          // 64 x 32 B = 2 KiB
    parameter D_LINES = 64;
    parameter WORDS   = 16384;       // 64 KiB, as sw/picolibc.ld

    reg clk = 0, rst = 1; wire tx, halted;
    always #5 clk = ~clk;

`ifdef CACHED
    soc_pipe_c #(.CACHE_EN(1), .LATENCY(LAT), .I_LINES(I_LINES), .D_LINES(D_LINES),
                 .ROM_WORDS(WORDS), .RAM_WORDS(WORDS), .BPRED(BPRED), .CLKS_PER_BIT(4)) dut (
        .clk(clk), .rst(rst), .uart_tx_pin(tx), .halted(halted));
`else
    soc_pipe_u #(.ROM_WORDS(WORDS), .RAM_WORDS(WORDS), .BPRED(BPRED), .CLKS_PER_BIT(4)) dut (
        .clk(clk), .rst(rst), .uart_tx_pin(tx), .halted(halted));
`endif

    reg [1023:0] img;
    integer cyc = 0, ret = 0, maxcyc = 50000000;

    always @(posedge clk)
        if (!rst && dut.sel_uart && dut.wr_any && dut.daddr[7:0] == 8'h00 && dut.dwdata[7:0] != 8'h0d)
            $write("%c", dut.dwdata[7:0]);
    always @(posedge clk) if (!rst && !halted) begin
        cyc = cyc + 1; if (dut.retire) ret = ret + 1;
    end
    // which kind of instruction the mispredictions are on (whole program)
    integer mp_br = 0, mp_jal = 0, mp_jalr = 0;
    wire mp_now = dut.u_core.ex_go & dut.u_core.mispred & ~dut.u_core.take_trap;
    always @(posedge clk) if (!rst && mp_now) begin
        if (dut.u_core.idex_jalr)      mp_jalr = mp_jalr + 1;
        else if (dut.u_core.idex_jump) mp_jal  = mp_jal + 1;
        else                           mp_br   = mp_br + 1;
    end

    initial begin
        if (!$value$plusargs("IMG=%s", img)) begin $display("need +IMG="); $finish; end
        if ($value$plusargs("MAXCYC=%d", maxcyc)) ;
`ifdef CACHED
        $readmemh(img, dut.u_imem.mem);
        $readmemh(img, dut.u_dmem.mem);
        $write("[bench] soc_pipe_c: caches %0d+%0d lines x 32 B, memory latency %0d, bpred %0d\n",
               I_LINES, D_LINES, LAT, BPRED);
`else
        $readmemh(img, dut.rom);
        $readmemh(img, dut.ram);
        $write("[bench] soc_pipe_u: ideal memory, bpred %0d\n", BPRED);
`endif
        repeat (3) @(posedge clk); #1; rst = 0;
        while (!halted && cyc < maxcyc) @(posedge clk);
        #1;
        if (!halted) $write("BENCH: FAIL (no halt after %0d cycles)\n", cyc);
        $write("[bench] whole program: %0d cycles, %0d retired\n", cyc, ret);
        $write("[bench] mispredictions: %0d branch, %0d jal, %0d jalr (returns, indirect calls)\n",
               mp_br, mp_jal, mp_jalr);
`ifdef CACHED
        $write("[bench] I$ %0d misses  D$ %0d misses  %0d writebacks\n",
               dut.g_cache.u_icache.n_miss, dut.g_cache.u_dcache.n_miss, dut.g_cache.u_dcache.n_wb);
`endif
        $finish;
    end
endmodule
`default_nettype wire
