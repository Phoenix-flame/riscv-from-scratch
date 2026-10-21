`timescale 1ns/1ps
`default_nettype none
// Step 42: the Step 41 TLB demo (sw/tlb.hex), unchanged, on the UNIFIED
// pipelined core. Same pass criteria as tb/tlb_tb.v: user code runs at VA
// 0x00403000 from PA 0x1000, the execute-only page gives exactly one load
// fault, the stale translation survives the PTE change until sfence.vma,
// and the run ends in a fetch page fault (mcause 12, mepc 0x00406000).
module pipe_u_tlb_tb;
    reg clk=0, rst=1; wire tx, halted;
    always #5 clk = ~clk;

    soc_pipe_u #(.ROM_WORDS(4096), .RAM_WORDS(8192),
                 .IMEM_INIT("sw/tlb.hex"), .CLKS_PER_BIT(4)) dut (
        .clk(clk), .rst(rst), .uart_tx_pin(tx), .halted(halted));

    always @(posedge clk)
        if (!rst && dut.sel_uart && dut.wr_any && (dut.daddr[7:0]==8'h00))
            $write("%c", dut.dwdata[7:0]);

    integer cyc=0, ret=0, walks=0, fails=0;
    always @(posedge clk) if (!rst && !halted) begin
        cyc = cyc + 1;
        if (dut.retire) ret = ret + 1;
        if (dut.u_core.ptw_start_d || dut.u_core.ptw_start_i)
            if (dut.u_core.g_ptw.u_ptw.state == 0) walks = walks + 1;
    end

    function [31:0] rd; input [31:0] pa; rd = dut.ram[pa>>2]; endfunction

    initial begin
        $write("---- Step 42: Step 41 TLB demo on the unified pipeline ----\n");
        repeat(3) @(posedge clk); #1; rst=0;
        while (!halted && cyc < 200000) @(posedge clk);
        #1;
        if (!halted)                      begin $write("FAIL: did not halt\n"); fails=fails+1; end
        if (rd(32'h7F10) !== 32'h600D)    begin $write("FAIL: no closing fault marker\n"); fails=fails+1; end
        if (rd(32'h7F00) !== 32'd12)      begin $write("FAIL: mcause=%0d, want 12\n", rd(32'h7F00)); fails=fails+1; end
        if (rd(32'h7F04) !== 32'h00406000) begin $write("FAIL: mepc=%h\n", rd(32'h7F04)); fails=fails+1; end
        if (rd(32'h7F08) !== 32'd1)       begin $write("FAIL: %0d load faults, want 1\n", rd(32'h7F08)); fails=fails+1; end
        if (rd(32'h7F0C) !== 32'd2)       begin $write("FAIL: %0d ecalls, want 2\n", rd(32'h7F0C)); fails=fails+1; end
        if (rd(32'h4004) !== 32'd5050)    begin $write("FAIL: checksum=%0d\n", rd(32'h4004)); fails=fails+1; end
        if (rd(32'h4000) !== 32'h22222222 || rd(32'h5000) !== 32'h33333333) begin
            $write("FAIL: PA4000=%h PA5000=%h, want 22222222 (stale) / 33333333\n", rd(32'h4000), rd(32'h5000));
            fails=fails+1; end
        $write("\n  cycles %0d  retired %0d  (CPI %0d.%02d)  page walks %0d\n",
               cyc, ret, cyc/ret, (cyc*100/ret)%100, walks);
        if (fails==0) $write("PIPE-U TLB: ALL PASS (Step 41 demo, unchanged, on the pipeline)\n");
        else          $write("PIPE-U TLB: %0d FAIL\n", fails);
        $finish;
    end
endmodule
`default_nettype wire
