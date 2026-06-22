`timescale 1ns/1ps
`default_nettype none
// Memory-isolated processes: two preempted user tasks, each with its own page
// table, switched via satp on every context switch. Self-checking on two axes:
//   preemption  - the UART output interleaves 'A' (task A) and 'b' (task B);
//   isolation   - both tasks write the SAME virtual address (0x1000) every
//                 pass, yet their private PHYSICAL pages end up holding their
//                 own task-tagged values (0xA....  vs 0xB....). If satp were
//                 not switched, only one physical page would ever be written.
module sched_mmu_tb;
    reg clk=0, rst=1; wire tx, halted;
    soc_fpga_mmu #(.ROM_WORDS(2048), .RAM_WORDS(16384),
                   .IMEM_INIT("sw/smmu.hex"), .CLKS_PER_BIT(4)) dut (
        .clk(clk), .rst(rst), .uart_tx_pin(tx), .halted(halted));
    always #5 clk = ~clk;

    // physical word addresses (PA >> 2)
    localparam PRIV_A = 32'h0000C000, PRIV_B = 32'h0000E000, FMARK = 32'h00007F08;
    function [31:0] rd; input [31:0] pa; rd = dut.u_ram.mem[pa>>2]; endfunction

    integer na=0, nb=0, g, fails;
    reg [31:0] va, vb;
    // snoop UART TX bytes (physical 0x10000000, offset 0)
    always @(posedge clk)
        if (!rst && dut.sel_uart && dut.wr_any && (dut.daddr[7:0]==8'h00)) begin
            $write("%c", dut.dwdata[7:0]);
            if (dut.dwdata[7:0]=="A") na = na + 1;
            if (dut.dwdata[7:0]=="b") nb = nb + 1;
        end

    initial begin
        $write("---- isolated processes: per-task page tables, satp switch ----\n");
        repeat(3) @(posedge clk); #1; rst=0;
        g=0;
        while (!halted && g<2000000) begin @(posedge clk); #1; g=g+1; end
        $write("\n");

        fails = 0;
        if (!halted) begin $write("FAIL: did not halt\n"); fails=fails+1; end
        // preemption: both tasks actually ran and interleaved
        if (na < 3) begin $write("FAIL: task A ran too little (%0d)\n", na); fails=fails+1; end
        if (nb < 3) begin $write("FAIL: task B ran too little (%0d)\n", nb); fails=fails+1; end
        // no unexpected page fault
        if (rd(FMARK) !== 32'h0) begin
            $write("FAIL: unexpected fault, mcause=%h pc=%h\n", rd(32'h7F00), rd(32'h7F04));
            fails=fails+1;
        end
        // isolation: each task's private physical page holds ITS OWN tag
        va = rd(PRIV_A); vb = rd(PRIV_B);
        if (va[31:28] !== 4'hA) begin
            $write("FAIL: task A private page = %h (expected 0xA.......)\n", va); fails=fails+1; end
        if (vb[31:28] !== 4'hB) begin
            $write("FAIL: task B private page = %h (expected 0xB.......)\n", vb); fails=fails+1; end
        // the two VA-0x1000 mappings are genuinely different physical pages
        if (va === vb) begin
            $write("FAIL: both private pages identical (%h) - not isolated\n", va); fails=fails+1; end

        $write("\nA-runs=%0d  b-runs=%0d  haltcycles=%0d\n", na, nb, g);
        $write("VA 0x1000 -> taskA phys page (PA 0xC000) = %h\n", va);
        $write("VA 0x1000 -> taskB phys page (PA 0xE000) = %h\n", vb);
        if (fails==0) $write("SCHED-MMU: ALL PASS (preemption + per-task isolation)\n");
        else          $write("SCHED-MMU: %0d FAIL\n", fails);
        $finish;
    end
endmodule
`default_nettype wire
