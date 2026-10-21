`timescale 1ns/1ps
`default_nettype none
// Step 43: the MMU programs through the caches. Two cached SoCs on slow
// memory (latency 7), with deliberately TINY caches -- 8 lines of 8 words,
// 256 bytes each side -- so code, data, page tables and stacks all fight for
// the same lines and dirty evictions happen constantly. Page-table walks read
// their PTEs through the D-cache, and kernel PTE stores sit dirty in it.
//   t : the Step 41 TLB demo (sw/tlb.hex), same pass criteria as before
//   s : Step 38's isolated processes, -DSCHED_VM build (sw/smmu_vm.hex)
// RAM is checked through soc_pipe_c's peek(): the newest copy of a word may
// still be in the write-back cache rather than in main memory.
module cache_sys_tb;
    reg clk=0, rst=1; always #5 clk = ~clk;
    wire tx_t, tx_s, h_t, h_s;

    soc_pipe_c #(.CACHE_EN(1), .LATENCY(7), .I_LINES(8), .D_LINES(8),
                 .ROM_WORDS(4096), .RAM_WORDS(8192), .CLKS_PER_BIT(4),
                 .IMEM_INIT("sw/tlb.hex")) t (
        .clk(clk), .rst(rst), .uart_tx_pin(tx_t), .halted(h_t));
    soc_pipe_c #(.CACHE_EN(1), .LATENCY(7), .I_LINES(8), .D_LINES(8),
                 .ROM_WORDS(2048), .RAM_WORDS(16384), .CLKS_PER_BIT(4),
                 .IMEM_INIT("sw/smmu_vm.hex")) s (
        .clk(clk), .rst(rst), .uart_tx_pin(tx_s), .halted(h_s));

    integer na = 0, nb = 0, cyc = 0, fails = 0;
    always @(posedge clk) if (!rst) begin
        cyc = cyc + 1;
        if (t.sel_uart && t.wr_any && t.daddr[7:0]==0) $write("%c", t.dwdata[7:0]);
        if (s.sel_uart && s.wr_any && s.daddr[7:0]==0) begin
            if (s.dwdata[7:0]=="A") na = na + 1;
            if (s.dwdata[7:0]=="b") nb = nb + 1;
        end
    end

    function [31:0] rt; input [31:0] pa; rt = t.g_cache.peek(pa); endfunction
    function [31:0] rs; input [31:0] pa; rs = s.g_cache.peek(pa); endfunction

    task want_eq; input [8*24:1] what; input [31:0] got, want;
        if (got !== want) begin $write("FAIL: %0s = %h, want %h\n", what, got, want); fails = fails + 1; end
    endtask

    reg [31:0] va, vb;
    initial begin
        $write("---- Step 43: MMU programs through 256-byte caches on slow memory ----\n");
        repeat(3) @(posedge clk); #1; rst=0;
        while (!(h_t && h_s) && cyc < 3000000) @(posedge clk);
        #1;
        if (!h_t) begin $write("FAIL: TLB demo did not halt\n"); fails = fails + 1; end
        if (!h_s) begin $write("FAIL: scheduler did not halt\n"); fails = fails + 1; end

        // ---- TLB demo (as tb/tlb_tb.v) ----
        want_eq("tlb: closing marker", rt(32'h7F10), 32'h600D);
        want_eq("tlb: mcause",         rt(32'h7F00), 32'd12);
        want_eq("tlb: mepc",           rt(32'h7F04), 32'h0040_6000);
        want_eq("tlb: load faults",    rt(32'h7F08), 32'd1);
        want_eq("tlb: ecalls",         rt(32'h7F0C), 32'd2);
        want_eq("tlb: checksum",       rt(32'h4004), 32'd5050);
        want_eq("tlb: PA 0x4000 stale",rt(32'h4000), 32'h22222222);
        want_eq("tlb: PA 0x5000",      rt(32'h5000), 32'h33333333);

        // ---- isolated processes (as tb/sched_mmu_tb.v) ----
        if (na < 3 || nb < 3) begin $write("FAIL: tasks ran %0d / %0d times\n", na, nb); fails = fails + 1; end
        want_eq("sched: fault marker", rs(32'h7F08), 32'h0);
        va = rs(32'h0000C000); vb = rs(32'h0000E000);
        if (va[31:28] !== 4'hA) begin $write("FAIL: task A page = %h\n", va); fails = fails + 1; end
        if (vb[31:28] !== 4'hB) begin $write("FAIL: task B page = %h\n", vb); fails = fails + 1; end

        $write("  tlb demo : I$ %0d misses, D$ %0d misses, %0d writebacks\n",
               t.g_cache.u_icache.n_miss, t.g_cache.u_dcache.n_miss, t.g_cache.u_dcache.n_wb);
        $write("  scheduler: A-runs=%0d b-runs=%0d  A page %h  B page %h  D$ %0d writebacks\n",
               na, nb, va, vb, s.g_cache.u_dcache.n_wb);
        if (fails == 0) $write("CACHE-SYS: ALL PASS (TLB demo + isolated processes through the caches)\n");
        else            $write("CACHE-SYS: %0d FAIL\n", fails);
        $finish;
    end
endmodule
`default_nettype wire
