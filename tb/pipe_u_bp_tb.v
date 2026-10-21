`timescale 1ns/1ps
`default_nettype none
// Step 44: the branch predictor folded into the unified pipeline. Two
// programs, each on two copies of cpu_pipe_u (ideal memory) that differ only
// in BPRED: 0 = predict not-taken (Step 42), 1 = BTB + 2-bit counters.
//   bench  - sw/bpred_bench.hex, Step 32's branchy workload; done when it
//            writes 0x600D to word 0x104, checksum at 0x100
//   cache  - sw/cb.hex (Step 43's benchmark), UART output vs the host's
// Reports control transfers, mispredictions and cycles for each.
module pipe_u_bp_tb;
    reg clk=0, rst=1; always #5 clk = ~clk;
    wire t0, t1, t2, t3, h0, h1, h2, h3;

    soc_pipe_u #(.BPRED(0), .CLKS_PER_BIT(4), .IMEM_INIT("sw/bpred_bench.hex")) b0 (
        .clk(clk), .rst(rst), .uart_tx_pin(t0), .halted(h0));
    soc_pipe_u #(.BPRED(1), .CLKS_PER_BIT(4), .IMEM_INIT("sw/bpred_bench.hex")) b1 (
        .clk(clk), .rst(rst), .uart_tx_pin(t1), .halted(h1));
    soc_pipe_u #(.BPRED(0), .CLKS_PER_BIT(4), .IMEM_INIT("sw/cb.hex"), .DMEM_INIT("sw/cb.hex")) c0 (
        .clk(clk), .rst(rst), .uart_tx_pin(t2), .halted(h2));
    soc_pipe_u #(.BPRED(1), .CLKS_PER_BIT(4), .IMEM_INIT("sw/cb.hex"), .DMEM_INIT("sw/cb.hex")) c1 (
        .clk(clk), .rst(rst), .uart_tx_pin(t3), .halted(h3));

    // ---- per-run counters; a run stops counting when it is done ----
    integer cyc[0:3], ctl[0:3], mis[0:3], k;
    reg     done[0:3];
    initial for (k = 0; k < 4; k = k + 1) begin cyc[k]=0; ctl[k]=0; mis[k]=0; done[k]=0; end

    `define COUNT(I, D) \
        if (!done[I]) begin cyc[I] = cyc[I] + 1; \
            if (D.u_core.bp_upd_en) ctl[I] = ctl[I] + 1; \
            if (D.u_core.bp_upd_en && D.u_core.mispred) mis[I] = mis[I] + 1; end
    always @(posedge clk) if (!rst) begin
        `COUNT(0, b0) `COUNT(1, b1) `COUNT(2, c0) `COUNT(3, c1)
        if (b0.dreq && |b0.dwe && b0.daddr == 32'h104 && b0.dwdata == 32'h600D) done[0] = 1;
        if (b1.dreq && |b1.dwe && b1.daddr == 32'h104 && b1.dwdata == 32'h600D) done[1] = 1;
        if (h2) done[2] = 1;
        if (h3) done[3] = 1;
    end

    // ---- UART capture for the cache bench ----
    reg [7:0] ob [0:1][0:255]; integer no [0:1];
    initial begin no[0] = 0; no[1] = 0; end
    always @(posedge clk) if (!rst) begin
        if (c0.sel_uart && c0.wr_any && c0.daddr[7:0]==0) begin ob[0][no[0]] = c0.dwdata[7:0]; no[0] = no[0]+1; end
        if (c1.sel_uart && c1.wr_any && c1.daddr[7:0]==0) begin ob[1][no[1]] = c1.dwdata[7:0]; no[1] = no[1]+1; end
    end

    integer fails = 0;
    task check_out; input integer w;
        integer fd, ch, i, bad;
        begin
            bad = 0; fd = $fopen("tb/cache_bench_expected.txt", "r");
            for (i = 0; i < no[w]; i = i + 1) begin ch = $fgetc(fd); if (ch != ob[w][i]) bad = 1; end
            if ($fgetc(fd) != -1) bad = 1;
            $fclose(fd);
            if (bad) begin $write("FAIL: cache bench output (BPRED=%0d) differs from the host's\n", w); fails = fails + 1; end
        end
    endtask

    task row; input [8*24:1] name; input integer i;
        $write("  %0s  ctrl %5d  mispredicted %5d (%0d.%01d%%)  cycles %6d\n", name, ctl[i], mis[i],
               mis[i]*100/ctl[i], (mis[i]*1000/ctl[i])%10, cyc[i]);
    endtask

    initial begin
        repeat(3) @(posedge clk); #1; rst=0;
        while (!(done[0] && done[1] && done[2] && done[3]) && cyc[2] < 2000000) @(posedge clk);
        #1;
        for (k = 0; k < 4; k = k + 1) if (!done[k]) begin $write("FAIL: run %0d did not finish\n", k); fails = fails + 1; end
        if (b0.ram[32'h100>>2] !== b1.ram[32'h100>>2] || b0.ram[32'h100>>2] !== 32'h0000_E6D8) begin
            $write("FAIL: bench checksum %h / %h, want 0000e6d8\n", b0.ram[32'h100>>2], b1.ram[32'h100>>2]);
            fails = fails + 1; end
        check_out(0); check_out(1);
        if (cyc[1] >= cyc[0] || cyc[3] >= cyc[2]) begin $write("FAIL: predictor not faster\n"); fails = fails + 1; end

        $write("---- Step 44: branch predictor in the unified pipeline ----\n");
        row("bpred bench, not-taken", 0); row("bpred bench, BTB+2-bit", 1);
        row("cache bench, not-taken", 2); row("cache bench, BTB+2-bit", 3);
        $write("  speedup: bpred bench %0d.%02dx   cache bench %0d.%02dx\n",
               cyc[0]/cyc[1], (cyc[0]*100/cyc[1])%100, cyc[2]/cyc[3], (cyc[2]*100/cyc[3])%100);
        if (fails == 0) $write("PIPE-U BP: ALL PASS\n");
        else            $write("PIPE-U BP: %0d FAIL\n", fails);
        $finish;
    end
endmodule
`default_nettype wire
