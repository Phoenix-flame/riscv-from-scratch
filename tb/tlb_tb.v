`timescale 1ns/1ps
`default_nettype none
// Step 41: translated instruction fetch + I/D TLBs. The same image runs on two
// SoCs side by side -- one with 4-entry TLBs, one with TLB_EN=0 (every fetch
// and every access walks) -- and the testbench checks both:
//   fetch translation  - user code runs at VA 0x00403000 from PA 0x1000
//   execute-only       - reading the code page is one load page fault
//   stale translation  - with a TLB, the store after the PTE change (but
//                        before sfence.vma) still lands in the OLD page
//   fetch fault        - jumping to a mapped, non-executable page gives
//                        mcause 12 with mepc = that VA
// and reports TLB hit/miss counts and the cycle cost of not having a TLB.
module tlb_tb;
    reg clk=0, rst=1;
    wire tx_t, tx_w, halt_t, halt_w;
    always #5 clk = ~clk;

    soc_fpga_tlb #(.TLB_EN(1), .ROM_WORDS(4096), .RAM_WORDS(8192),
                   .IMEM_INIT("sw/tlb.hex"), .CLKS_PER_BIT(4)) t (
        .clk(clk), .rst(rst), .uart_tx_pin(tx_t), .halted(halt_t));
    soc_fpga_tlb #(.TLB_EN(0), .ROM_WORDS(4096), .RAM_WORDS(8192),
                   .IMEM_INIT("sw/tlb.hex"), .CLKS_PER_BIT(4)) w (
        .clk(clk), .rst(rst), .uart_tx_pin(tx_w), .halted(halt_w));

    localparam S_FETCH=4'd0, S_EXEC=4'd1;
    localparam VA_CODE=32'h0040_3000, PA_CODE=32'h0000_1000;

    // UART echo (TLB SoC only)
    always @(posedge clk)
        if (!rst && t.sel_uart && t.wr_any && (t.daddr[7:0]==8'h00))
            $write("%c", t.dwdata[7:0]);

    integer fails = 0, g;

    // ---- per-SoC counters: translated fetches / data accesses, misses ----
    integer t_if=0, t_im=0, t_da=0, t_dm=0, t_cyc=0, t_remap=0;
    integer w_if=0, w_im=0, w_da=0, w_dm=0, w_cyc=0;
    always @(posedge clk) if (!rst) begin
        if (!halt_t) t_cyc = t_cyc + 1;
        if (!halt_w) w_cyc = w_cyc + 1;
        if (t.u_core.state==S_FETCH && t.u_core.xlate_active) begin
            t_if = t_if + 1;
            if (!t.u_core.itlb_hit) t_im = t_im + 1;
            // fetch translation: a VA_CODE PC must be served from PA_CODE
            if (t.u_core.pc[31:12]==VA_CODE[31:12] && t.u_core.itlb_hit) begin
                if (t.iaddr !== {PA_CODE[31:12], t.u_core.pc[11:0]}) begin
                    $write("FAIL: fetch pc=%h went to %h\n", t.u_core.pc, t.iaddr); fails = fails+1;
                end else t_remap = t_remap + 1;
            end
        end
        if (t.u_core.state==S_EXEC && t.u_core.xlate_active && t.u_core.is_mem && !t.u_core.exec_trap) begin
            t_da = t_da + 1;
            if (!t.u_core.dtlb_hit) t_dm = t_dm + 1;
        end
        if (w.u_core.state==S_FETCH && w.u_core.xlate_active) begin
            w_if = w_if + 1;
            if (!w.u_core.itlb_hit) w_im = w_im + 1;
        end
        if (w.u_core.state==S_EXEC && w.u_core.xlate_active && w.u_core.is_mem && !w.u_core.exec_trap) begin
            w_da = w_da + 1;
            if (!w.u_core.dtlb_hit) w_dm = w_dm + 1;
        end
    end

    function [31:0] rt; input [31:0] pa; rt = t.u_ram.mem[pa>>2]; endfunction
    function [31:0] rw; input [31:0] pa; rw = w.u_ram.mem[pa>>2]; endfunction

    // checks common to both SoCs
    task check_common;
        input [8*4:1] name;
        input [31:0] mcause, mepc, dfaults, ecalls, marker, csum, done;
        begin
            if (!done)              begin $write("FAIL[%0s]: did not halt\n", name); fails=fails+1; end
            if (marker !== 32'h600D) begin $write("FAIL[%0s]: no closing fault marker\n", name); fails=fails+1; end
            if (mcause !== 32'd12)  begin $write("FAIL[%0s]: mcause=%0d, want 12 (instr PF)\n", name, mcause); fails=fails+1; end
            if (mepc !== 32'h0040_6000) begin $write("FAIL[%0s]: mepc=%h, want 00406000\n", name, mepc); fails=fails+1; end
            if (dfaults !== 32'd1)  begin $write("FAIL[%0s]: %0d load faults on exec-only page, want 1\n", name, dfaults); fails=fails+1; end
            if (ecalls !== 32'd2)   begin $write("FAIL[%0s]: %0d ecalls, want 2\n", name, ecalls); fails=fails+1; end
            if (csum !== 32'd5050)  begin $write("FAIL[%0s]: checksum=%0d, want 5050\n", name, csum); fails=fails+1; end
        end
    endtask

    initial begin
        $write("---- Step 41: translated fetch + I/D TLBs ----\n");
        repeat(3) @(posedge clk); #1; rst=0;
        g = 0;
        while (!(halt_t && halt_w) && g < 400000) begin @(posedge clk); #1; g = g + 1; end

        check_common("tlb ", rt(32'h7F00), rt(32'h7F04), rt(32'h7F08), rt(32'h7F0C),
                     rt(32'h7F10), rt(32'h4004), halt_t);
        check_common("walk", rw(32'h7F00), rw(32'h7F04), rw(32'h7F08), rw(32'h7F0C),
                     rw(32'h7F10), rw(32'h4004), halt_w);

        // the stale-translation window: only the TLB core has one
        if (rt(32'h4000) !== 32'h22222222 || rt(32'h5000) !== 32'h33333333) begin
            $write("FAIL[tlb ]: PA4000=%h PA5000=%h, want 22222222 (stale) / 33333333\n",
                   rt(32'h4000), rt(32'h5000)); fails=fails+1; end
        if (rw(32'h4000) !== 32'h11111111 || rw(32'h5000) !== 32'h33333333) begin
            $write("FAIL[walk]: PA4000=%h PA5000=%h, want 11111111 / 33333333\n",
                   rw(32'h4000), rw(32'h5000)); fails=fails+1; end

        if (t_remap < 100) begin $write("FAIL: only %0d remapped fetches\n", t_remap); fails=fails+1; end
        if (t_im > 4)      begin $write("FAIL: %0d I-TLB misses, want <= 4\n", t_im); fails=fails+1; end
        if (t_dm > 6)      begin $write("FAIL: %0d D-TLB misses, want <= 6\n", t_dm); fails=fails+1; end
        if (w_im != w_if || w_dm != w_da) begin $write("FAIL: TLB_EN=0 core hit somewhere\n"); fails=fails+1; end
        if (t_cyc >= w_cyc) begin $write("FAIL: TLB core not faster\n"); fails=fails+1; end

        $write("\n                     fetches  I-miss   data  D-miss   cycles\n");
        $write("  %0d-entry TLBs     %8d %7d %6d %7d %8d\n", t.u_core.TLB_ENTRIES, t_if, t_im, t_da, t_dm, t_cyc);
        $write("  no TLB (walk)    %8d %7d %6d %7d %8d\n", w_if, w_im, w_da, w_dm, w_cyc);
        $write("  user fetches at VA 0x00403xxx served from PA 0x00001xxx: %0d\n", t_remap);
        $write("  stale store (PTE changed, no sfence yet): TLB -> PA 0x4000 = %h, walk -> PA 0x5000\n",
               rt(32'h4000));
        $write("  speedup %0d.%02dx\n", w_cyc / t_cyc, (w_cyc * 100 / t_cyc) % 100);
        if (fails == 0) $write("TLB: ALL PASS (fetch translation + I/D TLBs + sfence.vma + fetch faults)\n");
        else            $write("TLB: %0d FAIL\n", fails);
        $finish;
    end
endmodule
`default_nettype wire
